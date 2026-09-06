//! Blargg's `apu_test` conformance suite (ENG-71 acceptance criterion 1).
//! All 8 `rom_singles` ROMs, confirmed mapper 0/NROM -- see
//! `core/tests/roms/apu_test/ATTRIBUTION.md`. Same `$6000`-protocol harness
//! as `ppu_vbl_nmi_test.zig`/`nrom_sprite_input_test.zig`.

const harness = @import("blargg_harness.zig");
const expectPass = harness.expectPass;

test "apu_test 1-len_ctr" {
    try expectPass("apu_test/1-len_ctr", @embedFile("apu_test_1-len_ctr"));
}
test "apu_test 2-len_table" {
    try expectPass("apu_test/2-len_table", @embedFile("apu_test_2-len_table"));
}
test "apu_test 3-irq_flag" {
    try expectPass("apu_test/3-irq_flag", @embedFile("apu_test_3-irq_flag"));
}
test "apu_test 4-jitter" {
    try expectPass("apu_test/4-jitter", @embedFile("apu_test_4-jitter"));
}
test "apu_test 5-len_timing" {
    try expectPass("apu_test/5-len_timing", @embedFile("apu_test_5-len_timing"));
}
test "apu_test 6-irq_flag_timing" {
    try expectPass("apu_test/6-irq_flag_timing", @embedFile("apu_test_6-irq_flag_timing"));
}
test "apu_test 7-dmc_basics" {
    try expectPass("apu_test/7-dmc_basics", @embedFile("apu_test_7-dmc_basics"));
}
test "apu_test 8-dmc_rates" {
    try expectPass("apu_test/8-dmc_rates", @embedFile("apu_test_8-dmc_rates"));
}
