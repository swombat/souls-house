module TestSupport::E2e::InteractiveStoneFixtures

  def interactive_stone_fixture
    account = Account.find(params.fetch(:account_id))
    raise ActiveRecord::RecordNotFound unless Rails.env.test? && account.name.start_with?("E2E ")
    return head :unprocessable_entity unless StoneHosting.domain

    chat = account.chats.create!(title: "Private interactive source", model_id: "openrouter/auto")
    html = params[:html] || <<~HTML
      <!doctype html><html><head><title>Local instrument</title></head><body>
      <button id="play">Play tone</button><textarea id="score" aria-label="Score"></textarea>
      <button id="export">Write score</button><button id="load">Load score</button><p id="status">Silent</p>
      <script>
      let value = [1, 0, 3], audio;
      document.getElementById("play").onclick = async () => {
        audio = new AudioContext(); await audio.resume();
        const oscillator = audio.createOscillator(); oscillator.connect(audio.destination);
        oscillator.start(); oscillator.stop(audio.currentTime + 0.05);
        document.getElementById("status").textContent = audio.state;
      };
      document.getElementById("export").onclick = () => document.getElementById("score").value = JSON.stringify(value);
      document.getElementById("load").onclick = () => {
        value = JSON.parse(document.getElementById("score").value);
        document.getElementById("status").textContent = "Loaded " + value.join(",");
      };
      </script></body></html>
    HTML
    stone = Stone.publish!(chat: chat, title: "Interactive test stone", html: html,
      author: account.users.first!, public: true, interactive: true)
    if params[:hostile_html]
      # Deliberately bypass upload validation; headers/sandbox must stand alone.
      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(params[:hostile_html]),
        filename: "hostile.html", content_type: "text/html", identify: false, metadata: { stone_html: true })
      stone.latest_revision.html_attachment.update_column(:blob_id, blob.id)
    end
    render json: { url: stone.public_url, stone_id: stone.to_param }
  end

end
