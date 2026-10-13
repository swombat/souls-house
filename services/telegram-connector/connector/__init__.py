"""The souls.house Telegram connector (proposal 2026-10-11, slice S2a).

One process holds every connected Telegram user session. Rails sends it
signed commands over mutual TLS; it sends Rails signed events from a durable
outbox. See services/telegram-connector/README.md.
"""
