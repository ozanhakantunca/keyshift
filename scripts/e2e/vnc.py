import hashlib
import os
import re
import socket
import struct
import time
from pathlib import Path


SYMS = {
    "home": 0xFF50, "end": 0xFF57, "left": 0xFF51, "up": 0xFF52, "right": 0xFF53,
    "down": 0xFF54, "backspace": 0xFF08, "escape": 0xFF1B, "return": 0xFF0D,
    "delete": 0xFFFF, "shift": 0xFFE1, "ctrl": 0xFFE3, "alt": 0xFFE9, "cmd": 0xFFEB,
    "super": 0xFFEB, "meta": 0xFFE7, "f2": 0xFFBF, "f19": 0xFFCC, "f4": 0xFFC1, "space": 0x20,
}


def ard_password():
    """The console user's password for Screen Sharing (ARD) auth, read at runtime, never logged or stored.

    Set KEYSHIFT_VNC_PASSWORD, or KEYSHIFT_VNC_PASSWORD_FILE pointing at a file that contains it;
    otherwise the VNC cases are skipped with an error."""
    if os.environ.get("KEYSHIFT_VNC_PASSWORD"):
        return os.environ["KEYSHIFT_VNC_PASSWORD"]
    path = os.environ.get("KEYSHIFT_VNC_PASSWORD_FILE")
    if path and Path(path).expanduser().is_file():
        return Path(path).expanduser().read_text(encoding="utf-8").strip()
    raise RuntimeError("No Screen Sharing password available (set KEYSHIFT_VNC_PASSWORD or KEYSHIFT_VNC_PASSWORD_FILE)")


class RFB:
    """Screen Sharing client. Default: Apple Remote Desktop authentication (security type 30), which gives a
    controlling session. Legacy VNC auth (type 2) is view-only; it is available for explicit replays."""

    def __init__(self, username=None, security_type=30):
        self.security_type = security_type
        self.sent = []
        self.socket = socket.create_connection(("127.0.0.1", 5900), timeout=5)
        try:
            greeting = self.receive(12)
            self.server_version = greeting.rstrip().decode("ascii", errors="replace")
            if not greeting.startswith(b"RFB "):
                raise RuntimeError("Screen Sharing did not send an RFB greeting")
            self.socket.sendall(b"RFB 003.008\n")
            kinds = self.receive(self.receive(1)[0])
            if security_type not in kinds:
                raise RuntimeError(f"RFB security type {security_type} unavailable; offered {list(kinds)}")
            self.socket.sendall(bytes([security_type]))
            if security_type == 2:
                self.authenticate_legacy()
            else:
                self.authenticate_ard(username)
            if self.receive(4) != b"\0\0\0\0":
                raise RuntimeError(f"RFB security type {security_type} authentication rejected")
            self.socket.sendall(b"\x01")  # shared session
            info = self.receive(24)
            self.width, self.height = struct.unpack(">HH", info[:4])
            self.receive(struct.unpack(">I", info[-4:])[0])
            # Screen Sharing starts its client session when the first update is requested.
            self.socket.sendall(struct.pack(">B3xBBBBHHHBBB3x", 0, 32, 24, 0, 1,
                                            255, 255, 255, 0, 8, 16))
            self.socket.sendall(struct.pack(">BxHi", 2, 1, 0))  # Raw tiles only
            self.socket.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, 32, 32))
            self.receive_frame()
        except BaseException:
            self.socket.close()
            raise

    def authenticate_legacy(self):
        from cryptography.hazmat.decrepit.ciphers.algorithms import TripleDES
        from cryptography.hazmat.primitives.ciphers import Cipher, modes

        challenge = self.receive(16)
        password_file = Path(os.environ.get("KEYSHIFT_VNC_LEGACY_PASSWORD_FILE")
                             or Path.home() / "tools/.vnc-legacy-pw")
        password = password_file.read_bytes().rstrip(b"\r\n")[:8].ljust(8, b"\0")
        key = bytes(int(f"{byte:08b}"[::-1], 2) for byte in password)
        encryptor = Cipher(TripleDES(key * 3), modes.ECB()).encryptor()
        self.socket.sendall(encryptor.update(challenge) + encryptor.finalize())

    def authenticate_ard(self, username):
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

        generator = int.from_bytes(self.receive(2), "big")
        length = struct.unpack(">H", self.receive(2))[0]
        prime = int.from_bytes(self.receive(length), "big")
        server_public = int.from_bytes(self.receive(length), "big")
        private = int.from_bytes(os.urandom(length), "big") % (prime - 2) + 1
        client_public = pow(generator, private, prime).to_bytes(length, "big")
        shared = pow(server_public, private, prime).to_bytes(length, "big")
        key = hashlib.md5(shared).digest()
        account = (username or os.environ.get("USER", "")).encode("utf-8")[:63]
        secret = ard_password().encode("utf-8")[:63]
        block = bytearray(os.urandom(128))
        block[:len(account) + 1] = account + b"\0"
        block[64:64 + len(secret) + 1] = secret + b"\0"
        encryptor = Cipher(algorithms.AES(key), modes.ECB()).encryptor()
        self.socket.sendall(encryptor.update(bytes(block)) + encryptor.finalize() + client_public)

    def receive(self, count):
        result = bytearray()
        while len(result) < count:
            chunk = self.socket.recv(count - len(result))
            if not chunk:
                raise RuntimeError("Screen Sharing closed the connection")
            result.extend(chunk)
        return bytes(result)

    def receive_frame(self):
        while True:
            kind = self.receive(1)[0]
            if kind == 0:  # FramebufferUpdate
                self.receive(1)
                rectangles = struct.unpack(">H", self.receive(2))[0]
                for _ in range(rectangles):
                    _, _, width, height, encoding = struct.unpack(">HHHHi", self.receive(12))
                    if encoding != 0:
                        raise RuntimeError(f"Unexpected RFB framebuffer encoding {encoding}")
                    self.receive(width * height * 4)
                return
            if kind == 2:  # Bell
                continue
            if kind == 3:  # ServerCutText. Drain the wire without recording clipboard contents.
                self.receive(3)
                length = struct.unpack(">I", self.receive(4))[0]
                self.receive(length)
                continue
            raise RuntimeError(f"Unexpected RFB server message {kind}")

    def key(self, key, down):
        sym = SYMS[key] if key in SYMS else ord(key)
        self.socket.sendall(struct.pack(">BBHI", 4, int(down), 0, sym))
        self.sent.append({"keysym": sym, "down": down})
        time.sleep(0.027)

    def pointer(self, x, y, mask):
        self.socket.sendall(struct.pack(">BBHH", 5, mask, int(x), int(y)))

    def combo(self, combo, mapping):
        keys = [mapping.get(key, key) for key in combo.split("+")]
        held = []
        try:
            for key in keys:
                self.key(key, True)
                held.append(key)
        finally:
            for key in reversed(held):
                self.key(key, False)

    def close(self):
        self.socket.close()
