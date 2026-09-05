const std = @import("std");
const testing = std.testing;

/// NES bit order for a packed controller-buttons byte: bit0->bit7 is
/// A, B, Select, Start, Up, Down, Left, Right. This is both the order real
/// controller hardware shifts buttons out in (see `Controller.read`'s doc
/// comment) and the exact layout ENG-60 already locked in for the eventual
/// wasm `set_input(controller, buttons)` export -- so `setButtons` below
/// needs no bit-order translation when that export lands in M4.
pub const button_a: u8 = 0x01;
pub const button_b: u8 = 0x02;
pub const button_select: u8 = 0x04;
pub const button_start: u8 = 0x08;
pub const button_up: u8 = 0x10;
pub const button_down: u8 = 0x20;
pub const button_left: u8 = 0x40;
pub const button_right: u8 = 0x80;

/// One NES controller port: a parallel-in/serial-out shift register (a 4021
/// on real hardware), read a bit at a time through $4016 (port 0) or $4017
/// (port 1) -- see `Bus`'s doc comment for why $4017 is read-only for this
/// purpose (writes there are the APU frame counter, unrelated to input).
///
/// **Strobe.** Both ports share one physical strobe line, driven by every
/// write to $4016 regardless of which port is read (`Bus.write` calls
/// `setStrobe` on both). While asserted, the shift register continuously
/// reloads from the live button snapshot on every read -- so each read
/// returns bit 0 (the A button) over and over. On the falling edge the
/// register stops reloading and each subsequent read shifts the next bit
/// out LSB-first (A, B, Select, Start, Up, Down, Left, Right), then an
/// infinite tail of 1s once all 8 real bits are gone -- the open state of
/// an empty shift register, not a modeled bus-capacitance latch like
/// `Bus.open_bus`/`Ppu.data_bus` elsewhere in this codebase, but the same
/// "reads back whatever is actually there" spirit.
pub const Controller = struct {
    /// Live snapshot of which buttons are held, in NES bit order (see the
    /// module doc comment). Set only by `setButtons` -- there is no
    /// wasm/JS input path yet (ENG-68: M3 stays native-only), so nothing
    /// else writes it. A native test/debug harness is exactly what this
    /// milestone's own conformance and integration tests use it for.
    buttons: u8 = 0,
    /// The register `read` actually shifts out of.
    shift: u8 = 0,
    strobe: bool = false,

    pub fn setButtons(self: *Controller, buttons: u8) void {
        self.buttons = buttons;
    }

    /// Latch the shared strobe line. See the type doc comment for why this
    /// is called on *both* ports for every $4016 write.
    pub fn setStrobe(self: *Controller, asserted: bool) void {
        self.strobe = asserted;
        if (asserted) self.shift = self.buttons;
    }

    /// One serial bit out, LSB-first. Side-effecting: advances the shift
    /// register exactly like a real read, except while `strobe` holds it
    /// continuously reloaded (see the type doc comment).
    pub fn read(self: *Controller) u8 {
        if (self.strobe) self.shift = self.buttons;
        const bit = self.shift & 0x01;
        self.shift = (self.shift >> 1) | 0x80;
        return bit;
    }

    /// Side-effect-free counterpart to `read`, for `Bus.peek`. Never
    /// advances the shift register.
    pub fn peek(self: *const Controller) u8 {
        return if (self.strobe) self.buttons & 0x01 else self.shift & 0x01;
    }
};

test "while strobe is held, every read returns the live A-button bit" {
    var c = Controller{};
    c.setButtons(button_a | button_start);
    c.setStrobe(true);
    try testing.expectEqual(@as(u8, 1), c.read());
    try testing.expectEqual(@as(u8, 1), c.read()); // still A, strobe still held
    c.setButtons(0); // A released while strobe is still held
    try testing.expectEqual(@as(u8, 0), c.read());
}

test "after strobe falls, 8 reads shift out buttons LSB-first, then an open-bus tail of 1s" {
    var c = Controller{};
    c.setButtons(button_b | button_up); // bits 1 and 4
    c.setStrobe(true);
    c.setStrobe(false); // latches 0b0001_0010
    const expected = [_]u8{ 0, 1, 0, 0, 1, 0, 0, 0 }; // A,B,Select,Start,Up,Down,Left,Right
    for (expected) |bit| {
        try testing.expectEqual(bit, c.read());
    }
    try testing.expectEqual(@as(u8, 1), c.read());
    try testing.expectEqual(@as(u8, 1), c.read());
}

test "peek does not disturb the shift register" {
    var c = Controller{};
    c.setButtons(button_b); // bit 1
    c.setStrobe(true);
    c.setStrobe(false); // shift = 0b0000_0010
    const before = c.shift;
    _ = c.peek();
    try testing.expectEqual(before, c.shift);
    try testing.expectEqual(@as(u8, 0), c.read()); // A (bit0) is 0, as expected
    try testing.expectEqual(@as(u8, 1), c.read()); // B (bit1) is 1
}

test "setButtons changing mid-strobe is visible immediately (continuous reload)" {
    var c = Controller{};
    c.setStrobe(true);
    try testing.expectEqual(@as(u8, 0), c.read());
    c.setButtons(button_a);
    try testing.expectEqual(@as(u8, 1), c.read());
}
