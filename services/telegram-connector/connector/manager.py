"""All accounts in this process, and the command dispatch for the server."""

import logging

from .account import Account, Refused

log = logging.getLogger("telegram.manager")

OPERATIONS = ("start_login", "submit_password", "cancel_login", "logout", "search")


class Manager:
    def __init__(self, store, factory, post, settings=None, log_key=b""):
        self.store = store
        self.factory = factory
        self.post = post
        self.settings = settings
        self.log_key = log_key
        self.accounts = {}

    def account(self, ref, create=False):
        account = self.accounts.get(ref)
        if account is None and (create or self.store.connection(ref) is not None):
            account = Account(ref, self.store, self.factory, self.post, self.settings, self.log_key,
                              on_gone=self._gone)
            self.accounts[ref] = account
        return account

    def _gone(self, ref):
        self.accounts.pop(ref, None)

    async def boot(self):
        for row in self.store.connections():
            await self.account(row["ref"]).resume()

    async def close(self):
        for account in list(self.accounts.values()):
            await account.close()

    async def command(self, ref, operation, fields):
        """Returns (http status, reply dict). Fields were verified already."""
        try:
            if operation == "start_login":
                secret = fields.get("callback_secret")
                if not isinstance(secret, str) or not secret or len(secret) > 256:
                    raise Refused("bad_secret", 422)
                reply = await self.account(ref, create=True).start_login(
                    fields.get("generation"), secret, fields.get("callback_secret_version"))
            elif operation == "cancel_login":
                account = self.account(ref)
                reply = await account.cancel_login(fields.get("generation")) if account else {"status": "cancelled"}
            elif operation == "submit_password":
                account = self.account(ref)
                password = fields.pop("password", None)
                if account is None or not isinstance(password, str) or not password:
                    raise Refused("not_waiting_for_password")
                try:
                    reply = await account.submit_password(fields.get("generation"), password)
                finally:
                    password = None  # noqa: F841
            elif operation == "logout":
                account = self.account(ref)
                if account is None:
                    reply = {"status": "logged_out"}
                else:
                    reply = await account.logout()
                    self.accounts.pop(ref, None)
            elif operation == "search":
                account = self.account(ref)
                if account is None:
                    raise Refused("not_connected")
                reply = await account.search(fields.get("query"), fields.get("chat"), fields.get("limit"),
                                             fields.get("scope") or "synced")
            else:
                raise Refused("unknown_operation", 404)
        except Refused as refused:
            log.warning("command refused: op=%s reason=%s", operation, refused.code)
            return refused.status, {"error": refused.code}
        log.info("command done: op=%s", operation)
        return 200, reply
