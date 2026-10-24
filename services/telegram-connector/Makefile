# Tests and the Rails end-to-end test. PYTHON must have requirements.txt
# installed (python -m venv .venv && .venv/bin/pip install -r requirements.txt).
PYTHON ?= python3

.PHONY: test e2e

test:
	$(PYTHON) -m unittest discover -s tests -t . -p '*test*.py'

# Rails ↔ the real connector process, with the fake Telegram (run from the
# repository root's test environment; see README.md).
e2e:
	cd ../.. && COMMS_TELEGRAM_CONNECTOR_PYTHON=$(abspath $(shell which $(PYTHON))) bin/rails test test/integration/comms_telegram_connector_e2e_test.rb
