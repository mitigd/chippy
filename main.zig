const std = @import("std");

const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("ngui_c.h");
});

const display_w = 64;
const display_h = 32;
const scale = 2.0;

// CHIP-8 quirk toggles for compatibility/accuracy tuning.
// These defaults match original CHIP-8 behavior.
const quirk_shift_uses_vy = true; // 8xy6/8xyE read from Vy, store result in Vx
const quirk_loadstore_inc_i = true; // Fx55/Fx65 increment I by x+1

const font_start: u16 = 0x50;
const rom_start: u16 = 0x200;
const rom_capacity: usize = 4096 - @as(usize, rom_start);

const key_map = [_]c.SDL_Scancode{
    c.SDL_SCANCODE_X, // 0
    c.SDL_SCANCODE_1, // 1
    c.SDL_SCANCODE_2, // 2
    c.SDL_SCANCODE_3, // 3
    c.SDL_SCANCODE_Q, // 4
    c.SDL_SCANCODE_W, // 5
    c.SDL_SCANCODE_E, // 6
    c.SDL_SCANCODE_A, // 7
    c.SDL_SCANCODE_S, // 8
    c.SDL_SCANCODE_D, // 9
    c.SDL_SCANCODE_Z, // A
    c.SDL_SCANCODE_C, // B
    c.SDL_SCANCODE_4, // C
    c.SDL_SCANCODE_R, // D
    c.SDL_SCANCODE_F, // E
    c.SDL_SCANCODE_V, // F
};

const chip8_font = [_]u8{
    0xF0, 0x90, 0x90, 0x90, 0xF0,
    0x20, 0x60, 0x20, 0x20, 0x70,
    0xF0, 0x10, 0xF0, 0x80, 0xF0,
    0xF0, 0x10, 0xF0, 0x10, 0xF0,
    0x90, 0x90, 0xF0, 0x10, 0x10,
    0xF0, 0x80, 0xF0, 0x10, 0xF0,
    0xF0, 0x80, 0xF0, 0x90, 0xF0,
    0xF0, 0x10, 0x20, 0x40, 0x40,
    0xF0, 0x90, 0xF0, 0x90, 0xF0,
    0xF0, 0x90, 0xF0, 0x10, 0xF0,
    0xF0, 0x90, 0xF0, 0x90, 0x90,
    0xE0, 0x90, 0xE0, 0x90, 0xE0,
    0xF0, 0x80, 0x80, 0x80, 0xF0,
    0xE0, 0x90, 0x90, 0x90, 0xE0,
    0xF0, 0x80, 0xF0, 0x80, 0xF0,
    0xF0, 0x80, 0xF0, 0x80, 0x80,
};

const CpuHistory = struct {
    const len = 256;
    pc: [len]u16 = [_]u16{rom_start} ** len,
    opcode: [len]u16 = [_]u16{0} ** len,
    dt: [len]u8 = [_]u8{0} ** len,
    st: [len]u8 = [_]u8{0} ** len,
    idx: usize = 0,
    count: usize = 0,

    fn push(self: *CpuHistory, pc: u16, opcode: u16, dt: u8, st: u8) void {
        self.pc[self.idx] = pc;
        self.opcode[self.idx] = opcode;
        self.dt[self.idx] = dt;
        self.st[self.idx] = st;
        self.idx = (self.idx + 1) % len;
        if (self.count < len) self.count += 1;
    }
};

const Chip8 = struct {
    memory: [4096]u8 = [_]u8{0} ** 4096,
    v: [16]u8 = [_]u8{0} ** 16,
    i: u16 = 0,
    pc: u16 = rom_start,
    stack: [16]u16 = [_]u16{0} ** 16,
    sp: u8 = 0,
    delay_timer: u8 = 0,
    sound_timer: u8 = 0,
    keypad: [16]bool = [_]bool{false} ** 16,
    display: [display_w * display_h]u8 = [_]u8{0} ** (display_w * display_h),
    draw_flag: bool = false,
    waiting_for_key: bool = false,
    waiting_reg: u4 = 0,
    halted: bool = false,
    last_opcode: u16 = 0,
    prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0xC01DF00D),

    fn reset(self: *Chip8) void {
        self.* = Chip8{};
        @memcpy(self.memory[font_start .. font_start + chip8_font.len], chip8_font[0..]);
    }

    fn loadRom(self: *Chip8, data: []const u8) !void {
        if (data.len > self.memory.len - rom_start) return error.RomTooLarge;
        self.reset();
        @memcpy(self.memory[rom_start .. rom_start + data.len], data);
    }

    fn keyDown(self: *Chip8, key: usize) void {
        if (key < self.keypad.len) self.keypad[key] = true;
        if (self.waiting_for_key and key < 16) {
            self.v[self.waiting_reg] = @as(u8, @intCast(key));
            self.waiting_for_key = false;
        }
    }

    fn keyUp(self: *Chip8, key: usize) void {
        if (key < self.keypad.len) self.keypad[key] = false;
    }

    fn tickTimers(self: *Chip8) void {
        if (self.delay_timer > 0) self.delay_timer -= 1;
        if (self.sound_timer > 0) self.sound_timer -= 1;
    }

    fn fetch(self: *Chip8) u16 {
        const hi = self.memory[self.pc];
        const lo = self.memory[self.pc + 1];
        return (@as(u16, hi) << 8) | lo;
    }

    fn step(self: *Chip8) void {
        if (self.halted or self.waiting_for_key) return;
        if (self.pc >= self.memory.len - 1) {
            self.halted = true;
            return;
        }

        const opcode = self.fetch();
        self.last_opcode = opcode;
        self.pc +%= 2;

        const nnn = opcode & 0x0FFF;
        const n = @as(u4, @intCast(opcode & 0x000F));
        const x = @as(u4, @intCast((opcode >> 8) & 0x0F));
        const y = @as(u4, @intCast((opcode >> 4) & 0x0F));
        const kk = @as(u8, @intCast(opcode & 0x00FF));

        switch (opcode & 0xF000) {
            0x0000 => switch (opcode) {
                0x00E0 => {
                    @memset(self.display[0..], 0);
                    self.draw_flag = true;
                },
                0x00EE => {
                    if (self.sp == 0) {
                        self.halted = true;
                        return;
                    }
                    self.sp -= 1;
                    self.pc = self.stack[self.sp];
                },
                else => {},
            },
            0x1000 => self.pc = nnn,
            0x2000 => {
                if (self.sp >= self.stack.len) {
                    self.halted = true;
                    return;
                }
                self.stack[self.sp] = self.pc;
                self.sp += 1;
                self.pc = nnn;
            },
            0x3000 => {
                if (self.v[x] == kk) self.pc +%= 2;
            },
            0x4000 => {
                if (self.v[x] != kk) self.pc +%= 2;
            },
            0x5000 => {
                if (n == 0 and self.v[x] == self.v[y]) self.pc +%= 2;
            },
            0x6000 => self.v[x] = kk,
            0x7000 => self.v[x] +%= kk,
            0x8000 => switch (n) {
                0x0 => self.v[x] = self.v[y],
                0x1 => self.v[x] |= self.v[y],
                0x2 => self.v[x] &= self.v[y],
                0x3 => self.v[x] ^= self.v[y],
                0x4 => {
                    const sum = @as(u16, self.v[x]) + @as(u16, self.v[y]);
                    self.v[0xF] = if (sum > 0xFF) 1 else 0;
                    self.v[x] = @as(u8, @truncate(sum));
                },
                0x5 => {
                    self.v[0xF] = if (self.v[x] >= self.v[y]) 1 else 0;
                    self.v[x] -%= self.v[y];
                },
                0x6 => {
                    const src = if (quirk_shift_uses_vy) self.v[y] else self.v[x];
                    self.v[0xF] = src & 0x1;
                    self.v[x] = src >> 1;
                },
                0x7 => {
                    self.v[0xF] = if (self.v[y] >= self.v[x]) 1 else 0;
                    self.v[x] = self.v[y] -% self.v[x];
                },
                0xE => {
                    const src = if (quirk_shift_uses_vy) self.v[y] else self.v[x];
                    self.v[0xF] = (src >> 7) & 0x1;
                    self.v[x] = src << 1;
                },
                else => {},
            },
            0x9000 => {
                if (n == 0 and self.v[x] != self.v[y]) self.pc +%= 2;
            },
            0xA000 => self.i = nnn,
            0xB000 => self.pc = nnn + self.v[0],
            0xC000 => {
                const r = self.prng.random().int(u8);
                self.v[x] = r & kk;
            },
            0xD000 => {
                const vx = self.v[x] % display_w;
                const vy = self.v[y] % display_h;
                self.v[0xF] = 0;

                var row: usize = 0;
                while (row < n) : (row += 1) {
                    const sprite = self.memory[self.i + row];
                    var col: usize = 0;
                    while (col < 8) : (col += 1) {
                        const bit = (sprite >> @as(u3, @intCast(7 - col))) & 0x1;
                        if (bit == 0) continue;
                        const px = (vx + col) % display_w;
                        const py = (vy + row) % display_h;
                        const idx = py * display_w + px;
                        if (self.display[idx] == 1) self.v[0xF] = 1;
                        self.display[idx] ^= 1;
                    }
                }
                self.draw_flag = true;
            },
            0xE000 => switch (kk) {
                0x9E => {
                    if (self.keypad[self.v[x] & 0xF]) self.pc +%= 2;
                },
                0xA1 => {
                    if (!self.keypad[self.v[x] & 0xF]) self.pc +%= 2;
                },
                else => {},
            },
            0xF000 => switch (kk) {
                0x07 => self.v[x] = self.delay_timer,
                0x0A => {
                    self.waiting_for_key = true;
                    self.waiting_reg = x;
                },
                0x15 => self.delay_timer = self.v[x],
                0x18 => self.sound_timer = self.v[x],
                0x1E => self.i +%= self.v[x],
                0x29 => self.i = font_start + (@as(u16, self.v[x] & 0xF) * 5),
                0x33 => {
                    const val = self.v[x];
                    self.memory[self.i] = val / 100;
                    self.memory[self.i + 1] = (val / 10) % 10;
                    self.memory[self.i + 2] = val % 10;
                },
                0x55 => {
                    var r: usize = 0;
                    while (r <= x) : (r += 1) {
                        self.memory[self.i + r] = self.v[r];
                    }
                    if (quirk_loadstore_inc_i) self.i +%= @as(u16, @intCast(x + 1));
                },
                0x65 => {
                    var r: usize = 0;
                    while (r <= x) : (r += 1) {
                        self.v[r] = self.memory[self.i + r];
                    }
                    if (quirk_loadstore_inc_i) self.i +%= @as(u16, @intCast(x + 1));
                },
                else => {},
            },
            else => {},
        }
    }
};

fn decodeOpcode(op: u16, buf: []u8) []const u8 {
    const nnn = op & 0x0FFF;
    const n = op & 0x000F;
    const x = (op >> 8) & 0xF;
    const y = (op >> 4) & 0xF;
    const kk = op & 0xFF;

    return switch (op & 0xF000) {
        0x0000 => switch (op) {
            0x00E0 => std.fmt.bufPrint(buf, "CLS", .{}) catch "CLS",
            0x00EE => std.fmt.bufPrint(buf, "RET", .{}) catch "RET",
            else => std.fmt.bufPrint(buf, "SYS {X:0>3}", .{nnn}) catch "SYS",
        },
        0x1000 => std.fmt.bufPrint(buf, "JP {X:0>3}", .{nnn}) catch "JP",
        0x2000 => std.fmt.bufPrint(buf, "CALL {X:0>3}", .{nnn}) catch "CALL",
        0x3000 => std.fmt.bufPrint(buf, "SE V{X}, {X:0>2}", .{ x, kk }) catch "SE",
        0x4000 => std.fmt.bufPrint(buf, "SNE V{X}, {X:0>2}", .{ x, kk }) catch "SNE",
        0x5000 => std.fmt.bufPrint(buf, "SE V{X}, V{X}", .{ x, y }) catch "SE",
        0x6000 => std.fmt.bufPrint(buf, "LD V{X}, {X:0>2}", .{ x, kk }) catch "LD",
        0x7000 => std.fmt.bufPrint(buf, "ADD V{X}, {X:0>2}", .{ x, kk }) catch "ADD",
        0x8000 => switch (n) {
            0x0 => std.fmt.bufPrint(buf, "LD V{X}, V{X}", .{ x, y }) catch "LD",
            0x1 => std.fmt.bufPrint(buf, "OR V{X}, V{X}", .{ x, y }) catch "OR",
            0x2 => std.fmt.bufPrint(buf, "AND V{X}, V{X}", .{ x, y }) catch "AND",
            0x3 => std.fmt.bufPrint(buf, "XOR V{X}, V{X}", .{ x, y }) catch "XOR",
            0x4 => std.fmt.bufPrint(buf, "ADD V{X}, V{X}", .{ x, y }) catch "ADD",
            0x5 => std.fmt.bufPrint(buf, "SUB V{X}, V{X}", .{ x, y }) catch "SUB",
            0x6 => std.fmt.bufPrint(buf, "SHR V{X}", .{x}) catch "SHR",
            0x7 => std.fmt.bufPrint(buf, "SUBN V{X}, V{X}", .{ x, y }) catch "SUBN",
            0xE => std.fmt.bufPrint(buf, "SHL V{X}", .{x}) catch "SHL",
            else => std.fmt.bufPrint(buf, "8???", .{}) catch "8???",
        },
        0x9000 => std.fmt.bufPrint(buf, "SNE V{X}, V{X}", .{ x, y }) catch "SNE",
        0xA000 => std.fmt.bufPrint(buf, "LD I, {X:0>3}", .{nnn}) catch "LD I",
        0xB000 => std.fmt.bufPrint(buf, "JP V0, {X:0>3}", .{nnn}) catch "JP",
        0xC000 => std.fmt.bufPrint(buf, "RND V{X}, {X:0>2}", .{ x, kk }) catch "RND",
        0xD000 => std.fmt.bufPrint(buf, "DRW V{X}, V{X}, {X}", .{ x, y, n }) catch "DRW",
        0xE000 => switch (kk) {
            0x9E => std.fmt.bufPrint(buf, "SKP V{X}", .{x}) catch "SKP",
            0xA1 => std.fmt.bufPrint(buf, "SKNP V{X}", .{x}) catch "SKNP",
            else => std.fmt.bufPrint(buf, "E???", .{}) catch "E???",
        },
        0xF000 => switch (kk) {
            0x07 => std.fmt.bufPrint(buf, "LD V{X}, DT", .{x}) catch "LD",
            0x0A => std.fmt.bufPrint(buf, "LD V{X}, K", .{x}) catch "LD",
            0x15 => std.fmt.bufPrint(buf, "LD DT, V{X}", .{x}) catch "LD",
            0x18 => std.fmt.bufPrint(buf, "LD ST, V{X}", .{x}) catch "LD",
            0x1E => std.fmt.bufPrint(buf, "ADD I, V{X}", .{x}) catch "ADD",
            0x29 => std.fmt.bufPrint(buf, "LD F, V{X}", .{x}) catch "LD",
            0x33 => std.fmt.bufPrint(buf, "BCD V{X}", .{x}) catch "BCD",
            0x55 => std.fmt.bufPrint(buf, "LD [I], V0..V{X}", .{x}) catch "LD",
            0x65 => std.fmt.bufPrint(buf, "LD V0..V{X}, [I]", .{x}) catch "LD",
            else => std.fmt.bufPrint(buf, "F???", .{}) catch "F???",
        },
        else => std.fmt.bufPrint(buf, "????", .{}) catch "????",
    };
}

fn renderChip8(renderer: ?*c.SDL_Renderer, emu: *const Chip8, x: c_int, y: c_int, w: c_int, h: c_int) void {
    if (renderer == null or w <= 0 or h <= 0) return;

    var bg = c.SDL_FRect{ .x = @floatFromInt(x), .y = @floatFromInt(y), .w = @floatFromInt(w), .h = @floatFromInt(h) };
    _ = c.SDL_SetRenderDrawColor(renderer, 0x03, 0x05, 0x08, 0xFF);
    _ = c.SDL_RenderFillRect(renderer, &bg);

    const px_w = if (w > display_w) @divTrunc(w, display_w) else 1;
    const px_h = if (h > display_h) @divTrunc(h, display_h) else 1;

    _ = c.SDL_SetRenderDrawColor(renderer, 0x5A, 0xFF, 0x88, 0xFF);
    var py: usize = 0;
    while (py < display_h) : (py += 1) {
        var px: usize = 0;
        while (px < display_w) : (px += 1) {
            if (emu.display[py * display_w + px] == 0) continue;
            var cell = c.SDL_FRect{
                .x = @floatFromInt(x + @as(c_int, @intCast(px * @as(usize, @intCast(px_w))))),
                .y = @floatFromInt(y + @as(c_int, @intCast(py * @as(usize, @intCast(px_h))))),
                .w = @floatFromInt(px_w),
                .h = @floatFromInt(px_h),
            };
            _ = c.SDL_RenderFillRect(renderer, &cell);
        }
    }
}

fn renderHistoryGraph(renderer: ?*c.SDL_Renderer, history: *const CpuHistory, x: c_int, y: c_int, w: c_int, h: c_int) void {
    if (renderer == null or w <= 8 or h <= 8) return;
    var bg = c.SDL_FRect{ .x = @floatFromInt(x), .y = @floatFromInt(y), .w = @floatFromInt(w), .h = @floatFromInt(h) };
    _ = c.SDL_SetRenderDrawColor(renderer, 0x10, 0x12, 0x18, 0xFF);
    _ = c.SDL_RenderFillRect(renderer, &bg);

    const count = if (history.count == 0) 1 else history.count;
    var i: c_int = 0;
    while (i < w) : (i += 1) {
        const src = (@as(usize, @intCast(i)) * count) / @as(usize, @intCast(w));
        const idx = (history.idx + CpuHistory.len - history.count + src) % CpuHistory.len;
        const dt = history.dt[idx];
        const st = history.st[idx];

        const dt_h: c_int = @intFromFloat((@as(f32, @floatFromInt(dt)) / 255.0) * @as(f32, @floatFromInt(h)));
        const st_h: c_int = @intFromFloat((@as(f32, @floatFromInt(st)) / 255.0) * @as(f32, @floatFromInt(h)));

        _ = c.SDL_SetRenderDrawColor(renderer, 0x30, 0xB0, 0xFF, 0xD0);
        var dt_bar = c.SDL_FRect{
            .x = @floatFromInt(x + i),
            .y = @floatFromInt(y + h - dt_h),
            .w = 1,
            .h = @floatFromInt(dt_h),
        };
        _ = c.SDL_RenderFillRect(renderer, &dt_bar);

        _ = c.SDL_SetRenderDrawColor(renderer, 0xFF, 0x8A, 0x30, 0xB0);
        var st_bar = c.SDL_FRect{
            .x = @floatFromInt(x + i),
            .y = @floatFromInt(y + h - st_h),
            .w = 1,
            .h = @floatFromInt(st_h),
        };
        _ = c.SDL_RenderFillRect(renderer, &st_bar);
    }
}

fn scancodeToChip8(scancode: c.SDL_Scancode) ?usize {
    for (key_map, 0..) |scan, idx| {
        if (scan == scancode) return idx;
    }
    return null;
}

fn basename(path: []const u8) []const u8 {
    var i: usize = path.len;
    while (i > 0) : (i -= 1) {
        const ch = path[i - 1];
        if (ch == '/' or ch == '\\') return path[i..];
    }
    return path;
}

fn elideTail(text: []const u8, max_len: usize) []const u8 {
    if (text.len <= max_len) return text;
    if (max_len <= 3) return text[text.len - max_len ..];
    return text[text.len - (max_len - 3) ..];
}

pub fn main() !void {
    if (c.SDL_Init(c.SDL_INIT_VIDEO) == false) return error.SDLInitFailed;
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow("chippy", 1400, 900, 0) orelse return error.SDLWindowFailed;
    defer c.SDL_DestroyWindow(window);

    const renderer = c.SDL_CreateRenderer(window, null) orelse return error.SDLRendererFailed;
    defer c.SDL_DestroyRenderer(renderer);
    _ = c.SDL_SetRenderScale(renderer, scale, scale);

    const ngui = c.ngui_create(renderer) orelse return error.NguiInitFailed;
    defer c.ngui_destroy(ngui);

    var emu = Chip8{};
    emu.reset();

    var input = c.NGUI_Input{
        .mouse_x = 0,
        .mouse_y = 0,
        .mouse_down = 0,
        .mouse_pressed = 0,
        .mouse_wheel = 0,
    };

    var running = true;
    var paused = false;
    var step_once = false;
    var step_10 = false;
    var show_about = false;
    var open_browser = false;
    var rom_loaded = false;
    var cycles_per_frame: f32 = 10;
    var timer_accum: f64 = 0;
    var status_text: [256]u8 = [_]u8{0} ** 256;
    var status_len: usize = 0;
    var loaded_rom: [rom_capacity]u8 = undefined;
    var loaded_rom_len: usize = 0;

    var history = CpuHistory{};

    const perf_freq = c.SDL_GetPerformanceFrequency();
    var last_counter = c.SDL_GetPerformanceCounter();

    while (running) {
        const now_counter = c.SDL_GetPerformanceCounter();
        const elapsed = now_counter - last_counter;
        last_counter = now_counter;
        const dt = if (perf_freq == 0) 0.016 else @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(perf_freq));
        timer_accum += dt;

        input.mouse_pressed = 0;
        input.mouse_wheel = 0;

        var ev: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&ev)) {
            if (ev.type == c.SDL_EVENT_QUIT) running = false;
            if (ev.type == c.SDL_EVENT_MOUSE_MOTION) {
                input.mouse_x = @intFromFloat(ev.motion.x / scale);
                input.mouse_y = @intFromFloat(ev.motion.y / scale);
            }
            if (ev.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN and ev.button.button == c.SDL_BUTTON_LEFT) {
                input.mouse_x = @intFromFloat(ev.button.x / scale);
                input.mouse_y = @intFromFloat(ev.button.y / scale);
                input.mouse_down = 1;
                input.mouse_pressed = 1;
            }
            if (ev.type == c.SDL_EVENT_MOUSE_BUTTON_UP and ev.button.button == c.SDL_BUTTON_LEFT) {
                input.mouse_x = @intFromFloat(ev.button.x / scale);
                input.mouse_y = @intFromFloat(ev.button.y / scale);
                input.mouse_down = 0;
            }
            if (ev.type == c.SDL_EVENT_MOUSE_WHEEL) {
                if (ev.wheel.y > 0) input.mouse_wheel += 1;
                if (ev.wheel.y < 0) input.mouse_wheel -= 1;
            }
            if (ev.type == c.SDL_EVENT_KEY_DOWN and ev.key.repeat == false) {
                if (ev.key.scancode == c.SDL_SCANCODE_SPACE) paused = !paused;
                if (ev.key.scancode == c.SDL_SCANCODE_F10) step_once = true;
                if (scancodeToChip8(ev.key.scancode)) |chip_key| emu.keyDown(chip_key);
            }
            if (ev.type == c.SDL_EVENT_KEY_UP) {
                if (scancodeToChip8(ev.key.scancode)) |chip_key| emu.keyUp(chip_key);
            }
        }

        var mx: f32 = 0;
        var my: f32 = 0;
        const mouse_buttons = c.SDL_GetMouseState(&mx, &my);
        input.mouse_x = @intFromFloat(mx / scale);
        input.mouse_y = @intFromFloat(my / scale);
        input.mouse_down = if ((mouse_buttons & c.SDL_BUTTON_LMASK) != 0) 1 else 0;

        const cycles = @as(usize, @intFromFloat(if (cycles_per_frame < 1) 1 else cycles_per_frame));
        if (rom_loaded and !emu.halted) {
            if (!paused) {
                var ci: usize = 0;
                while (ci < cycles) : (ci += 1) {
                    const pc_before = emu.pc;
                    emu.step();
                    history.push(pc_before, emu.last_opcode, emu.delay_timer, emu.sound_timer);
                    if (emu.waiting_for_key or emu.halted) break;
                }
            } else if (step_once or step_10) {
                const steps: usize = if (step_10) 10 else 1;
                var si: usize = 0;
                while (si < steps) : (si += 1) {
                    const pc_before = emu.pc;
                    emu.step();
                    history.push(pc_before, emu.last_opcode, emu.delay_timer, emu.sound_timer);
                    if (emu.waiting_for_key or emu.halted) break;
                }
                step_once = false;
                step_10 = false;
            }

            while (timer_accum >= (1.0 / 60.0)) {
                emu.tickTimers();
                timer_accum -= 1.0 / 60.0;
            }
        }

        _ = c.SDL_SetRenderDrawColor(renderer, 0x07, 0x0A, 0x10, 0xFF);
        _ = c.SDL_RenderClear(renderer);

        c.ngui_begin_frame(ngui, &input);

        c.ngui_begin_main_menu_bar(ngui);
        if (c.ngui_begin_main_menu(ngui, "FILE") != 0) {
            if (c.ngui_main_menu_item(ngui, "OPEN ROM") != 0) open_browser = true;
            if (c.ngui_main_menu_item(ngui, "RESET") != 0 and rom_loaded) {
                emu.loadRom(loaded_rom[0..loaded_rom_len]) catch |err| {
                    status_len = blk: {
                        const s = std.fmt.bufPrint(&status_text, "Reset failed: {s}", .{@errorName(err)}) catch break :blk 0;
                        break :blk s.len;
                    };
                    rom_loaded = false;
                    c.ngui_end_main_menu(ngui);
                    c.ngui_end_main_menu_bar(ngui);
                    c.ngui_end_frame(ngui);
                    _ = c.SDL_RenderPresent(renderer);
                    continue;
                };
                history = CpuHistory{};
                paused = false;
                status_len = blk: {
                    const s = std.fmt.bufPrint(&status_text, "Reset ROM", .{}) catch break :blk 0;
                    break :blk s.len;
                };
            }
            if (c.ngui_main_menu_item(ngui, "EXIT") != 0) running = false;
            c.ngui_end_main_menu(ngui);
        }
        if (c.ngui_begin_main_menu(ngui, "EMULATION") != 0) {
            if (c.ngui_main_menu_item(ngui, if (paused) "RUN" else "PAUSE") != 0) paused = !paused;
            if (c.ngui_main_menu_item(ngui, "STEP") != 0) {
                paused = true;
                step_once = true;
            }
            if (c.ngui_main_menu_item(ngui, "STEP X10") != 0) {
                paused = true;
                step_10 = true;
            }
            c.ngui_end_main_menu(ngui);
        }
        if (c.ngui_begin_main_menu(ngui, "HELP") != 0) {
            if (c.ngui_main_menu_item(ngui, "ABOUT") != 0) show_about = true;
            c.ngui_end_main_menu(ngui);
        }
        c.ngui_end_main_menu_bar(ngui);

        var out_w: c_int = 0;
        var out_h: c_int = 0;
        _ = c.SDL_GetRenderOutputSize(renderer, &out_w, &out_h);
        const ui_w: c_int = @max(@as(c_int, 320), @as(c_int, @intFromFloat(@as(f32, @floatFromInt(out_w)) / scale)));
        const ui_h: c_int = @max(@as(c_int, 240), @as(c_int, @intFromFloat(@as(f32, @floatFromInt(out_h)) / scale)));

        const margin: c_int = 15;
        const top: c_int = 22;
        const avail_w: c_int = ui_w - (margin * 3);
        // Right side: Registers and Stack/Keys side-by-side (takes most space)
        // Left side: Display on top, small Graph below
        var left_w: c_int = @divTrunc(avail_w * 4, 10);
        if (left_w < 120) left_w = 120;
        if (left_w > avail_w - 300) left_w = avail_w - 300;
        var right_w: c_int = avail_w - left_w;
        if (right_w < 300) {
            right_w = 300;
            left_w = avail_w - right_w;
            if (left_w < 120) {
                left_w = 120;
                right_w = avail_w - left_w;
            }
        }
        const right_x: c_int = margin * 2 + left_w;
        const avail_h: c_int = ui_h - top - margin;

        var graph_win_h: c_int = 80; // Small fixed height
        var display_win_h: c_int = avail_h - graph_win_h - margin;
        if (display_win_h < 120) {
            display_win_h = 120;
            graph_win_h = avail_h - display_win_h - margin;
        }

        const control_h: c_int = 130; // Compact fixed control area
        const lower_right_h: c_int = avail_h - control_h - margin;

        // Disasm at bottom (full width of right column)
        var disasm_h: c_int = 80;
        if (disasm_h > lower_right_h - 150) disasm_h = lower_right_h - 150;
        if (disasm_h < 80) disasm_h = 80;

        // Middle section (Registers | Stack | Keys side-by-side)
        var mid_h: c_int = lower_right_h - disasm_h - margin;
        if (mid_h < 150) mid_h = 150;

        const split_gap: c_int = 8;
        const col_w: c_int = @divTrunc(right_w - split_gap * 2, 3);
        const reg_w: c_int = col_w;
        const stack_w: c_int = col_w;
        const keys_w: c_int = right_w - reg_w - stack_w - split_gap * 2;

        const DrawPanel = enum { display, graph, control, registers, stack, keys, disasm };
        var panels: [7]DrawPanel = .{ .display, .graph, .control, .registers, .stack, .keys, .disasm };
        var panel_z: [7]c_int = .{
            c.ngui_get_window_z(ngui, "CHIP-8 DISPLAY"),
            c.ngui_get_window_z(ngui, "KADE TIMER GRAPHS"),
            c.ngui_get_window_z(ngui, "CONTROL"),
            c.ngui_get_window_z(ngui, "REGISTERS"),
            c.ngui_get_window_z(ngui, "STACK"),
            c.ngui_get_window_z(ngui, "KEYS"),
            c.ngui_get_window_z(ngui, "DISASM (PC WINDOW)"),
        };

        var pi: usize = 0;
        while (pi < panels.len) : (pi += 1) {
            var pj: usize = pi + 1;
            while (pj < panels.len) : (pj += 1) {
                if (panel_z[pj] < panel_z[pi]) {
                    const tz = panel_z[pi];
                    panel_z[pi] = panel_z[pj];
                    panel_z[pj] = tz;
                    const tp = panels[pi];
                    panels[pi] = panels[pj];
                    panels[pj] = tp;
                }
            }
        }

        for (panels) |panel| {
            switch (panel) {
                .display => {
                    var vx: c_int = 0;
                    var vy: c_int = 0;
                    var vw: c_int = 0;
                    var vh: c_int = 0;
                    if (c.ngui_begin_render_window(ngui, "CHIP-8 DISPLAY", margin, top, left_w, display_win_h, 1, &vx, &vy, &vw, &vh) != 0) {
                        renderChip8(renderer, &emu, vx, vy, vw, vh);
                        c.ngui_end_window(ngui);
                    }
                },
                .graph => {
                    var gx: c_int = 0;
                    var gy: c_int = 0;
                    var gw: c_int = 0;
                    var gh: c_int = 0;
                    if (c.ngui_begin_render_window(ngui, "KADE TIMER GRAPHS", margin, top + display_win_h + margin, left_w, graph_win_h, 0, &gx, &gy, &gw, &gh) != 0) {
                        renderHistoryGraph(renderer, &history, gx, gy, gw, gh);
                        c.ngui_end_window(ngui);
                    }
                },
                .control => {
                    if (c.ngui_begin_window(ngui, "CONTROL", right_x, top, right_w, control_h) != 0) {
                        var running_toggle = !paused;
                        if (c.ngui_checkbox(ngui, "Running", &running_toggle, 8, 0) != 0) paused = !running_toggle;

                        if (c.ngui_button(ngui, "Step", 8, 2, 70, 16) != 0) {
                            paused = true;
                            step_once = true;
                        }
                        if (c.ngui_button(ngui, "Step x10", 86, 2, 70, 16) != 0) {
                            paused = true;
                            step_10 = true;
                        }

                        c.ngui_spacer(ngui, 20);

                        c.ngui_label(ngui, "Cycles/frame", 8, 2);
                        _ = c.ngui_slider(ngui, null, &cycles_per_frame, 1, 80, 8, 2, -16);

                        var line: [96]u8 = undefined;
                        const st = std.fmt.bufPrintZ(&line, "PC={X:0>4} I={X:0>4} SP={d}", .{ emu.pc, emu.i, emu.sp }) catch "state";
                        c.ngui_label(ngui, st.ptr, 8, 2);

                        var opbuf: [96]u8 = undefined;
                        var disbuf: [96]u8 = undefined;
                        const op = std.fmt.bufPrintZ(&opbuf, "OP={X:0>4}", .{emu.last_opcode}) catch "op";
                        c.ngui_label(ngui, op.ptr, 8, 2);

                        const dis = decodeOpcode(emu.last_opcode, disbuf[0..]);
                        var disz: [100]u8 = undefined;
                        const dis_line = std.fmt.bufPrintZ(&disz, "{s}", .{dis}) catch "decode";
                        c.ngui_label(ngui, dis_line.ptr, 8, 2);

                        var timer_buf: [96]u8 = undefined;
                        const t = std.fmt.bufPrintZ(&timer_buf, "DT={d} ST={d}", .{ emu.delay_timer, emu.sound_timer }) catch "timers";
                        c.ngui_label(ngui, t.ptr, 8, 2);

                        if (status_len > 0) {
                            var status_z: [260]u8 = undefined;
                            const shown = elideTail(status_text[0..status_len], 46);
                            const s = std.fmt.bufPrintZ(&status_z, "Status: {s}", .{shown}) catch "status";
                            c.ngui_separator(ngui, 8, 4, 0);
                            c.ngui_label(ngui, s.ptr, 8, 2);
                        }

                        c.ngui_end_window(ngui);
                    }
                },

                .registers => {
                    if (c.ngui_begin_window(ngui, "REGISTERS", right_x, top + control_h + margin, reg_w, mid_h) != 0) {
                        var i: usize = 0;
                        while (i < 16) : (i += 1) {
                            var line: [64]u8 = undefined;
                            const txt = std.fmt.bufPrintZ(&line, "V{X}: {X:0>2} ({d})", .{ i, emu.v[i], emu.v[i] }) catch "reg";
                            c.ngui_label(ngui, txt.ptr, 8, 3);
                        }
                        c.ngui_end_window(ngui);
                    }
                },
                .stack => {
                    if (c.ngui_begin_window(ngui, "STACK", right_x + reg_w + split_gap, top + control_h + margin, stack_w, mid_h) != 0) {
                        var si: usize = 0;
                        while (si < emu.stack.len) : (si += 1) {
                            var line: [64]u8 = undefined;
                            const marker: u8 = if (si + 1 == emu.sp) '*' else ' ';
                            const txt = std.fmt.bufPrintZ(&line, "{c} {d: >2}: {X:0>4}", .{ marker, si, emu.stack[si] }) catch "stack";
                            c.ngui_label(ngui, txt.ptr, 8, 2);
                        }
                        c.ngui_end_window(ngui);
                    }
                },
                .keys => {
                    if (c.ngui_begin_window(ngui, "KEYS", right_x + reg_w + split_gap + stack_w + split_gap, top + control_h + margin, keys_w, mid_h) != 0) {
                        var k: usize = 0;
                        while (k < 16) : (k += 1) {
                            var key_line: [48]u8 = undefined;
                            const txt = std.fmt.bufPrintZ(&key_line, "{X}: {s}", .{ k, if (emu.keypad[k]) "down" else "up" }) catch "key";
                            c.ngui_label(ngui, txt.ptr, 8, 1);
                        }
                        c.ngui_end_window(ngui);
                    }
                },
                .disasm => {
                    if (c.ngui_begin_window(ngui, "DISASM (PC WINDOW)", right_x, top + control_h + margin + mid_h + margin, right_w, disasm_h) != 0) {
                        var row: usize = 0;
                        while (row < 14) : (row += 1) {
                            const addr = emu.pc + @as(u16, @intCast(row * 2));
                            if (addr + 1 >= emu.memory.len) break;
                            const op = (@as(u16, emu.memory[addr]) << 8) | emu.memory[addr + 1];
                            var dbuf: [64]u8 = undefined;
                            const dis = decodeOpcode(op, dbuf[0..]);
                            var line: [128]u8 = undefined;
                            const txt = std.fmt.bufPrintZ(&line, "{X:0>3}:{X:0>4} {s}", .{ addr, op, dis }) catch "dis";
                            c.ngui_label(ngui, txt.ptr, 8, 1);
                        }
                        c.ngui_end_window(ngui);
                    }
                },
            }
        }

        if (open_browser) {
            c.ngui_open_file_browser(ngui);
            open_browser = false;
        }
        if (c.ngui_show_file_browser(ngui)) |picked| {
            open_browser = false;
            const path = std.mem.span(picked);
            const file = std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 1024 * 1024) catch |err| {
                status_len = blk: {
                    const s = std.fmt.bufPrint(&status_text, "Failed to load ROM: {s}", .{@errorName(err)}) catch break :blk 0;
                    break :blk s.len;
                };
                rom_loaded = false;
                loaded_rom_len = 0;
                c.ngui_end_frame(ngui);
                _ = c.SDL_RenderPresent(renderer);
                continue;
            };
            defer std.heap.page_allocator.free(file);

            emu.loadRom(file) catch |err| {
                status_len = blk: {
                    const s = std.fmt.bufPrint(&status_text, "Invalid ROM: {s}", .{@errorName(err)}) catch break :blk 0;
                    break :blk s.len;
                };
                rom_loaded = false;
                loaded_rom_len = 0;
                c.ngui_end_frame(ngui);
                _ = c.SDL_RenderPresent(renderer);
                continue;
            };
            @memcpy(loaded_rom[0..file.len], file);
            loaded_rom_len = file.len;
            rom_loaded = true;
            paused = false;
            history = CpuHistory{};
            const short_name = basename(path);
            status_len = blk: {
                const s = std.fmt.bufPrint(&status_text, "Loaded ROM: {s}", .{short_name}) catch break :blk 0;
                break :blk s.len;
            };
        }

        if (show_about) {
            if (c.ngui_message_box_ex(
                ngui,
                "about",
                "ABOUT CHIPPY",
                "CHIP-8 + SDL3 +\nnesticle_gui debug build \n\nby: mitigd",
                c.NGUI_MSGBOX_ONE_BUTTON,
                "OK",
                null,
                c.NGUI_TEXT_ALIGN_CENTER,
            ) != 0) show_about = false;
        }

        c.ngui_end_frame(ngui);
        _ = c.SDL_RenderPresent(renderer);
    }
}
