# Field OCR: a PDF page with no text of its own (a scan), or very little
# (a typed heading over a scanned body), is rendered to an image inside the
# house and sent to Claude Haiku 5.5 to be transcribed. The transcription is
# kept apart from the page's own text and labelled as a model's.
#
# What is sent: one greyscale image of the page (longer side 1568 px) and a
# fixed instruction. Through the house's OpenRouter key, pinned to Anthropic
# with no fallback and data_collection "deny", the same route as summaries:
# Anthropic doesn't train on it and may keep it for up to 30 days.
#
# Checked 2026-10-11 08:03 UTC (https://openrouter.ai/api/v1/models and
# .../models/anthropic/claude-haiku-5.5/endpoints): anthropic/claude-haiku-5.5
# takes image input; the Anthropic endpoint charges $0.10 per million input
# tokens and $0.50 per million output tokens.
#
# Off until a site admin turns it on (Setting#field_ocr_enabled), and then
# only for files brought in after that moment (field_ocr_enabled_at): the
# Field already holding scans is not sent anywhere by this. Spend is
# reserved before every call (FieldOcrCall) against
# Setting#field_ocr_daily_usd_ceiling, under one lock, with per-file and
# per-account page limits.
module FieldOcr

  MODEL = "anthropic/claude-haiku-5.5"
  PROVIDER = "anthropic"
  MAX_TOKENS = 4_000
  # Reserved per call before it is made: the most one call can cost at the
  # prices above (an image of at most ~3.3k tokens plus the prompt, and
  # MAX_TOKENS out), rounded up. Settled down to the real cost afterwards.
  RESERVE_USD = BigDecimal("0.003")
  # A page with a picture and less text of its own than this is transcribed
  # too. A heuristic, not a proof: a scan with a long typed caption is missed.
  SPARSE_CHARS = 200
  MAX_PAGES_PER_FILE = 50
  MAX_PAGES_PER_ACCOUNT_PER_DAY = 500
  # A reservation newer than this is taken to be another worker's call in
  # flight; that page is left to it.
  IN_FLIGHT = 10.minutes
  MAX_TEXT_CHARS = 64_000
  NO_TEXT = "[no text]"
  LOCK_KEY = "field_ocr_ledger"

  SYSTEM = PromptTemplate.render("transcribe_field_page", :system).freeze

  class LimitReached < StandardError; end

  # Not a setting. Test credentials carry a house key, so test_helper turns
  # this off; tests that exercise OCR turn it on and stub the call.
  mattr_accessor :live, default: true

  module_function

  def enabled?
    setting = Setting.instance
    live && setting.field_ocr_enabled && setting.field_ocr_enabled_at.present? && HouseInference::Offering.configured?
  end

  # Brought in after OCR was turned on. Older files are never sent here.
  def eligible?(file)
    enabled? && file.created_at >= Setting.instance.field_ocr_enabled_at
  end

  # page: a FieldFilePage or a row hash with the same keys.
  def candidate?(page)
    case page[:native_status]
    when "empty" then true
    # A little text and a picture: maybe a typed heading over a scan.
    when "text" then page[:has_images] == true && page[:native_text].to_s.strip.length < SPARSE_CHARS
    else false
    end
  end

  def day = Time.current.utc.to_date

  def status_json
    setting = Setting.instance
    { enabled: setting.field_ocr_enabled, enabled_at: setting.field_ocr_enabled_at&.iso8601,
      ceiling_usd: setting.field_ocr_daily_usd_ceiling.to_s, spent_today: FieldOcrCall.on(day).sum(:charge_usd).to_s }
  end

  # => a reserved FieldOcrCall, :done (this page already has a settled
  # transcription) or :in_flight (another worker is on it). Raises
  # LimitReached with the reason. One lock over the whole ledger, so two
  # workers can't both take the last of the allowance.
  def reserve!(file, page_number, now: Time.current)
    FieldOcrCall.transaction do
      FieldOcrCall.connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{FieldOcrCall.connection.quote(LOCK_KEY)}))")
      calls = FieldOcrCall.where(field_file_id: file.id, page_number: page_number)
      return :done if calls.where(status: "settled").exists?
      return :in_flight if calls.where(status: "reserved").where(created_at: (now - IN_FLIGHT)..).exists?

      # Charged calls count; a reservation given back before sending doesn't.
      charged = FieldOcrCall.where("charge_usd > 0").or(FieldOcrCall.where(status: "reserved"))
      today = FieldOcrCall.on(day)
      if charged.where(field_file_id: file.id).distinct.count(:page_number) >= MAX_PAGES_PER_FILE
        raise LimitReached, "Only #{MAX_PAGES_PER_FILE} pages of a file are transcribed"
      end
      if charged.merge(today).where(account_id: file.account_id).count >= MAX_PAGES_PER_ACCOUNT_PER_DAY
        raise LimitReached, "This account's transcriptions for today are used up"
      end
      ceiling = Setting.instance.field_ocr_daily_usd_ceiling.to_d
      if today.sum(:charge_usd) + RESERVE_USD > ceiling
        raise LimitReached, "The house's transcription budget for today is used up"
      end

      FieldOcrCall.create!(account_id: file.account_id, field_file: file, page_number: page_number,
        day: day, status: "reserved", charge_usd: RESERVE_USD, model_id: MODEL)
    end
  end

  # => { status: "text"|"empty", text:, cut: } for one page image. Raises
  # UtilityInference::Error when the call fails.
  # timeout: seconds the call may take (the caller's remaining budget).
  def transcribe(png, page_number:, page_count:, timeout:, inference: UtilityInference)
    answer = inference.house_vision(model: MODEL, provider: PROVIDER, system: SYSTEM,
      text: PromptTemplate.render("transcribe_field_page", :user, page_number:, page_count:),
      image_png: png, max_tokens: MAX_TOKENS, timeout: timeout)
    text = answer[:text].to_s.scrub("").delete("\u0000").strip
    # Anything but a normal stop means the answer may be incomplete: the
    # token limit ("length"), or the provider stopping it ("content_filter",
    # seen live on a page of repeated words, 2026-10-11, after one line).
    finish = answer[:finish_reason].to_s
    cut = finish != "stop" || text.length > MAX_TEXT_CHARS
    cut_reason = if text.length > MAX_TEXT_CHARS then "too long"
    elsif finish == "length" then "token limit"
    elsif finish == "content_filter" then "stopped by the provider"
    elsif finish != "stop" then "ended early (#{finish.presence || "no reason given"})"
    end
    text = text[0, MAX_TEXT_CHARS]
    # A cut answer with no text isn't a blank page: nothing can be said.
    status = if text.empty? || text == NO_TEXT then (cut ? "failed" : "empty") else "text" end
    answer.merge(status: status, text: (text if status == "text"), cut: cut, cut_reason: cut_reason)
  end

end
