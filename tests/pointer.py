"""Small Wayland virtual pointer for integration tests (no extra packages).

Uses wl_display/wl_registry and wlr-virtual-pointer-unstable-v1 version 1.
Keep the connection alive across a gesture so button state is preserved.
"""
import os
import socket
import struct
import time


class VirtualPointer:
    def __init__(self, env, width, height):
        self.width, self.height = width, height
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(5)
        display = env["WAYLAND_DISPLAY"]
        self.socket.connect(display if display.startswith("/") else
                            os.path.join(env["XDG_RUNTIME_DIR"], display))
        self.next_id = 3
        self.manager = None
        self.send(1, 1, 2)  # wl_display.get_registry
        self.roundtrip()
        if self.manager is None:
            self.close()
            raise RuntimeError("Compositor does not support virtual pointers")
        interface = b"zwlr_virtual_pointer_manager_v1\0"
        string = struct.pack("=I", len(interface)) + interface
        string += b"\0" * (-len(interface) % 4)
        self.message(2, 0, struct.pack("=I", self.manager) + string + struct.pack("=II", 1, 4))
        self.next_id = 6
        self.send(4, 0, 0, 5)  # create_virtual_pointer(null seat, id)
        self.roundtrip()

    def message(self, object_id, opcode, payload=b""):
        self.socket.sendall(struct.pack("=II", object_id, (len(payload) + 8) << 16 | opcode) + payload)

    def send(self, object_id, opcode, *args):
        self.message(object_id, opcode, struct.pack("=" + "I" * len(args), *args))

    def receive(self, size):
        data = b""
        while len(data) < size:
            chunk = self.socket.recv(size - len(data))
            if not chunk:
                raise RuntimeError("Compositor closed virtual pointer connection")
            data += chunk
        return data

    def roundtrip(self):
        callback = self.next_id
        self.next_id += 1
        self.send(1, 0, callback)
        while True:
            object_id, header = struct.unpack("=II", self.receive(8))
            opcode, size = header & 0xffff, header >> 16
            payload = self.receive(size - 8)
            if object_id == 1 and opcode == 0:
                raise RuntimeError("Wayland protocol error: " + repr(payload))
            if object_id == 2 and opcode == 0:
                name, length = struct.unpack_from("=II", payload)
                if payload[8:8 + length - 1] == b"zwlr_virtual_pointer_manager_v1":
                    self.manager = name
            if object_id == callback and opcode == 0:
                return

    def move(self, x, y):
        self.send(5, 1, self.timestamp(), round(x), round(y), self.width, self.height)
        self.frame()

    def button(self, pressed, button=272):
        self.send(5, 2, self.timestamp(), button, int(pressed))
        self.frame()

    def frame(self):
        self.send(5, 4)
        self.roundtrip()

    @staticmethod
    def timestamp():
        return int(time.monotonic() * 1000) & 0xffffffff

    def close(self):
        self.socket.close()
