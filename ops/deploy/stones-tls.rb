#!/usr/bin/env ruby
# Host-only. No Rails, dotenv gem, shell evaluation, or proxy/deployment commands.
require "openssl"
require "tempfile"
require "socket"
require "timeout"

class StonesTls

  CERT = "STONES_TLS_CERTIFICATE_PEM"
  KEY = "STONES_TLS_PRIVATE_KEY_PEM"
  NAMES = [ CERT, KEY ].freeze
  class Invalid < StandardError; end

  def initialize(secrets: "/etc/house-deploy/secrets", lock: "/var/lib/house-deploy/deployment.lock", store: nil)
    @secrets, @lock = secrets, lock
    @store = store || OpenSSL::X509::Store.new.tap(&:set_default_paths)
  end

  # Preserve unrelated entries byte-for-byte. Fail closed on unsupported dotenv
  # syntax rather than guessing where a multiline secret ends. Never evaluate it.
  def entries(text)
    result = []
    until text.empty?
      if (match = /\A[ \t]*(?:#[^\n]*)?(?:\n|\z)/.match(text)) && !match[0].empty?
        chunk, name = match[0], nil
      else
        match = /\A[ \t]*(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*/.match(text)
        raise Invalid, "Unsupported secrets file syntax" unless match
        name = match[1]
        start = match[0].bytesize
        quote = text.byteslice(start, 1)
        if [ "'", '"' ].include?(quote)
          cursor = start + 1
          loop do
            raise Invalid, "Unclosed secrets value" if cursor >= text.bytesize
            char = text.byteslice(cursor, 1)
            break if char == quote
            cursor += 1 if char == "\\" # dotenv permits escaped quotes
            cursor += 1
          end
          ending = /\A[ \t]*(?:#[^\n]*)?(?:\n|\z)/.match(text.byteslice(cursor + 1..))
          raise Invalid, "Unsupported quoted secrets value" unless ending
          chunk = text.byteslice(0, cursor + 1 + ending[0].bytesize)
        else
          chunk = text.lines.first
          raise Invalid, "Unsupported unquoted secrets value" if chunk.byteslice(start..).match?(/['"\\]/)
        end
      end
      result << [ name, chunk ]
      text = text.byteslice(chunk.bytesize..)
    end
    raise Invalid, "Duplicate TLS secrets" if NAMES.any? { |name| result.count { |entry| entry[0] == name } > 1 }
    result
  end

  def pair_from(entries)
    pair = entries.select { |name, _| NAMES.include?(name) }.to_h
    raise Invalid, "Incomplete TLS secret pair" unless pair.empty? || pair.size == 2
    pair.transform_values do |entry|
      # Only literal multiline PEM is accepted for the owned entries.
      match = /=\s*(['"])(.*?)\1[ \t]*(?:#[^\n]*)?\n?\z/m.match(entry)
      raise Invalid, "TLS secrets must be quoted literal PEM" unless match
      match[2]
    end
  end

  def validate(pair, domain:, days: 1, now: Time.now)
    raise Invalid, "Invalid stones domain" unless domain.match?(/\A[a-z0-9]+(?:[.-][a-z0-9]+)*\.[a-z]{2,}\z/)
    pem = pair.fetch(CERT)
    blocks = pem.scan(/-----BEGIN CERTIFICATE-----\n[A-Za-z0-9+\/=\n]+-----END CERTIFICATE-----\n?/)
    raise Invalid, "Invalid certificate chain PEM" if blocks.empty? || blocks.join != pem
    chain = blocks.map { |block| OpenSSL::X509::Certificate.new(block) }
    leaf = chain.first
    private_pem = pair.fetch(KEY)
    unless private_pem.match?(/\A-----BEGIN ((?:RSA |EC )?)PRIVATE KEY-----\n[A-Za-z0-9+\/=\n]+-----END \1PRIVATE KEY-----\n?\z/)
      raise Invalid, "Invalid or encrypted private key PEM"
    end
    key = OpenSSL::PKey.read(private_pem, "")
    key.private_to_der
    raise Invalid, "Certificate/key mismatch" unless leaf.check_private_key(key)
    raise Invalid, "Certificate not valid long enough" unless chain.all? { |cert| cert.not_before <= now && cert.not_after > now + days * 86_400 }
    names = leaf.extensions.select { |ext| ext.oid == "subjectAltName" }.flat_map { |ext| ext.value.split(/,\s*/) }
    raise Invalid, "Missing explicit stones wildcard SAN" unless names.include?("DNS:*.#{domain}")
    raise Invalid, "Untrusted or incomplete certificate chain" unless @store.verify(leaf, chain.drop(1))
    leaf
  rescue OpenSSL::OpenSSLError, ArgumentError, KeyError
    raise Invalid, "Invalid TLS certificate or private key"
  end

  def render(pair)
    NAMES.map { |name| "#{name}='#{pair.fetch(name)}'\n" }.join
  end

  def safe_read(path)
    stat = File.lstat(path)
    unless stat.file? && stat.uid == Process.euid && (stat.mode & 0o077).zero?
      raise Invalid, "Secret file must be owner-only regular file"
    end
    File.binread(path)
  end

  def prepare_inputs(paths)
    paths.each do |path|
      # acme.sh writes public fullchain.cer as 0644. Harden ONLY the two
      # designated files through an opened descriptor, never following a final
      # symlink or chmodding a substituted pathname.
      File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        stat = file.stat
        raise Invalid, "TLS input must be owner-owned regular file" unless stat.file? && stat.uid == Process.euid
        file.chmod(0o600)
      end
    end
  end

  def atomic_write(path, content)
    Tempfile.create([ ".stones-tls-", ".tmp" ], File.dirname(path)) do |file|
      file.chmod(0o600)
      file.write(content)
      file.flush
      file.fsync
      File.rename(file.path, path)
      File.open(File.dirname(path), File::RDONLY, &:fsync)
    end
  end

  def locked
    File.open(@lock, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
      raise Invalid, "Deployment busy; retry later" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
      yield
    end
  end

  def install(fullchain:, key:, domain:, dry_run: false)
    locked do
      pair = { CERT => safe_read(fullchain), KEY => safe_read(key) }
      validate(pair, domain: domain)
      original = safe_read(@secrets)
      parsed = entries(original)
      previous = pair_from(parsed)
      return :validated if dry_run
      return :unchanged if previous == pair
      # Backup is committed before the single atomic replacement containing BOTH
      # new values. An interrupted install leaves the current pair intact.
      atomic_write("#{@secrets}.stones-previous", render(previous)) unless previous.empty?
      rest = parsed.reject { |name, _| NAMES.include?(name) }.map(&:last).join
      rest += "\n" unless rest.empty? || rest.end_with?("\n")
      atomic_write(@secrets, rest + render(pair))
      :installed
    end
  end

  def check(domain:, host:, days: 21, port: 443)
    leaf = locked { validate(pair_from(entries(safe_read(@secrets))), domain: domain, days: days) }
    unless host.end_with?(".#{domain}") && host.delete_suffix(".#{domain}").match?(/\A[a-z0-9-]+\z/)
      raise Invalid, "Probe host must be one stones subdomain"
    end
    Timeout.timeout(15) do
      Socket.tcp(host, port, connect_timeout: 10) do |tcp|
        context = OpenSSL::SSL::SSLContext.new
        context.set_params
        context.cert_store = @store
        tls = OpenSSL::SSL::SSLSocket.new(tcp, context)
        begin
          tls.hostname = host
          tls.connect
          tls.post_connection_check(host)
          raise Invalid, "Installed certificate not served; manual Deploy Rails required" unless tls.peer_cert.to_der == leaf.to_der
        ensure
          tls.close
        end
      end
    end
    :healthy
  end

end

if $PROGRAM_NAME == __FILE__
  begin
    raise StonesTls::Invalid, "Run as host root" unless Process.uid.zero?
    operation, *args = ARGV
    tls = StonesTls.new
    case [ operation, args.length ]
    when [ "prepare", 2 ]
      tls.prepare_inputs(args)
      puts "TLS input permissions secured"
    when [ "preflight", 3 ]
      tls.install(domain: args[0], fullchain: args[1], key: args[2], dry_run: true)
      puts "validated; no files changed or TLS refreshed"
    when [ "install", 3 ]
      result = tls.install(domain: args[0], fullchain: args[1], key: args[2])
      puts result
      warn "TLS pair installed/unchanged. NOT refreshed: notify operator to approve manual Deploy Rails, then verify live TLS."
    when [ "check", 2 ]
      tls.check(domain: args[0], host: args[1])
      puts "Installed and served TLS match; more than 21 days remain."
    else
      raise StonesTls::Invalid, "Usage: stones-tls.rb prepare FULLCHAIN KEY | preflight|install DOMAIN FULLCHAIN KEY | check DOMAIN PROBE_HOST"
    end
  rescue StonesTls::Invalid => error
    warn "Stone TLS: #{error.message}"
    exit 1
  rescue StandardError
    # Do not print parser, filesystem, network errors or backtraces: inputs may
    # contain secrets. External monitoring must alert on this nonzero status.
    warn "Stone TLS: operation failed; notify operator (no secret details logged)"
    exit 1
  end
end
