FROM python:3.11.13-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY download.py .
RUN HF_HUB_DISABLE_TELEMETRY=1 python download.py /model
COPY server.py model-sha256.json ./
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin embeddings
USER embeddings
ENV HF_HUB_OFFLINE=1 HF_HUB_DISABLE_TELEMETRY=1
EXPOSE 8080
CMD ["python", "server.py", "--model-dir", "/model", "--host", "0.0.0.0"]
