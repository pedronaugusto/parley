//! `requestState`: what a handler keeps across the rounds of a multi
//! round-trip request, carried by the client and given back on its retry.
//! The client is not trusted with it (2026-07-28 MRTR, server requirements
//! 4 and 5): it is sealed with XChaCha20-Poly1305 under the server's key,
//! bound to who asked (the transport's principal), what was asked (the
//! method and the tool, prompt or resource it names) and an expiry, so it
//! can be neither read, changed, replayed on another request nor kept past
//! its time.
//!
//! Sealed: base64url of `version (1) | nonce (24) | ciphertext | tag (16)`,
//! the ciphertext holding `expiry ms (8, big-endian) | payload`.
const std = @import("std");
const aegis = @import("aegis");

const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const base64 = std.base64.url_safe_no_pad;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const version: u8 = 1;
const overhead = 1 + Aead.nonce_length + 8 + Aead.tag_length;

/// The server's sealing key and how long a seal holds.
pub const Sealer = struct {
    key: aegis.Secret([Aead.key_length]u8),
    ttl: Io.Duration,

    /// A sealer with a key drawn now: state sealed by one process opens only
    /// in it. A cluster that retries on another member gives every member
    /// one key, with `withKey`.
    pub fn init(io: Io, ttl: Io.Duration) Io.RandomSecureError!Sealer {
        var key: [Aead.key_length]u8 = undefined;
        defer std.crypto.secureZero(u8, &key);
        try io.randomSecure(&key);
        return withKey(key, ttl);
    }

    pub fn withKey(key: [Aead.key_length]u8, ttl: Io.Duration) Sealer {
        return .{ .key = .init(key), .ttl = ttl };
    }

    pub fn deinit(s: *Sealer) void {
        s.key.deinit();
    }

    /// `payload` sealed for the request `binding` names, on `arena`.
    pub fn seal(s: *const Sealer, io: Io, arena: Allocator, binding: Binding, payload: []const u8) SealError![]const u8 {
        const expiry = Io.Timestamp.now(io, .real).addDuration(s.ttl).toMilliseconds();
        const raw = try arena.alloc(u8, overhead + payload.len);
        raw[0] = version;
        const nonce = raw[1..][0..Aead.nonce_length];
        try io.randomSecure(nonce);
        var plain = try arena.alloc(u8, 8 + payload.len);
        std.mem.writeInt(i64, plain[0..8], expiry, .big);
        @memcpy(plain[8..], payload);
        const sealed = raw[1 + Aead.nonce_length ..][0..plain.len];
        const tag = raw[raw.len - Aead.tag_length ..][0..Aead.tag_length];
        var ad: AssociatedData = .{};
        Aead.encrypt(sealed, tag, plain, ad.of(binding), nonce.*, s.key.expose().*);
        std.crypto.secureZero(u8, plain);
        const text = try arena.alloc(u8, base64.Encoder.calcSize(raw.len));
        return base64.Encoder.encode(text, raw);
    }

    /// The payload `sealed` holds, when it was sealed by this key for this
    /// request and has not expired.
    pub fn open(s: *const Sealer, io: Io, arena: Allocator, binding: Binding, sealed: []const u8) OpenError![]const u8 {
        const len = base64.Decoder.calcSizeForSlice(sealed) catch return error.Tampered;
        if (len < overhead) return error.Tampered;
        const raw = try arena.alloc(u8, len);
        base64.Decoder.decode(raw, sealed) catch return error.Tampered;
        if (raw[0] != version) return error.Tampered;
        const nonce = raw[1..][0..Aead.nonce_length];
        const cipher = raw[1 + Aead.nonce_length .. raw.len - Aead.tag_length];
        const tag = raw[raw.len - Aead.tag_length ..][0..Aead.tag_length];
        const plain = try arena.alloc(u8, cipher.len);
        var ad: AssociatedData = .{};
        Aead.decrypt(plain, cipher, tag.*, ad.of(binding), nonce.*, s.key.expose().*) catch return error.Tampered;
        const expiry = std.mem.readInt(i64, plain[0..8], .big);
        if (Io.Timestamp.now(io, .real).toMilliseconds() >= expiry) return error.Expired;
        return plain[8..];
    }
};

pub const SealError = Allocator.Error || Io.RandomSecureError;

/// `Tampered`: not sealed by this key for this request (changed, forged, or
/// from another request or principal). `Expired`: sealed, but too long ago.
pub const OpenError = error{ Tampered, Expired, OutOfMemory };

/// What a seal is bound to.
pub const Binding = struct {
    /// Who asked, as the transport authenticated them; null when it did not.
    principal: ?[]const u8,
    /// The request's method.
    method: []const u8,
    /// The tool or prompt name, or the resource URI.
    subject: []const u8,
};

/// The binding as one byte string, each part length-prefixed so no two
/// bindings spell the same bytes.
const AssociatedData = struct {
    hash: [32]u8 = undefined,

    fn of(ad: *AssociatedData, b: Binding) []const u8 {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        for ([_][]const u8{ b.principal orelse "", b.method, b.subject }, 0..) |part, i| {
            var len: [9]u8 = undefined;
            len[0] = if (i == 0 and b.principal == null) 0 else 1;
            std.mem.writeInt(u64, len[1..9], part.len, .big);
            h.update(&len);
            h.update(part);
        }
        h.final(&ad.hash);
        return &ad.hash;
    }
};
