#!/usr/bin/env python3
"""Generate Bongo's Zig 0.16 TLS Client compatibility backport.

Input must be the unmodified Zig 0.16.0
lib/std/crypto/tls/Client.zig. The generated file keeps Zig's implementation
and applies only the compatibility changes Bongo needs:

* import the public `std` module from outside Zig's stdlib tree;
* accept TLS 1.2/1.3 CertificateRequest when Bongo has no client certificate;
* include CertificateRequest and the empty client Certificate in the transcript;
* send an empty client Certificate before Finished/ClientKeyExchange as required.

The script uses exact-string assertions deliberately. If the upstream source
shape changes, generation fails rather than silently producing a questionable
TLS implementation.
"""

from __future__ import annotations

import pathlib
import re
import sys


def replace_once(source: str, old: str, new: str, label: str) -> str:
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return source.replace(old, new, 1)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: vendor_zig_0_16_tls_client.py INPUT OUTPUT")

    input_path = pathlib.Path(sys.argv[1])
    output_path = pathlib.Path(sys.argv[2])
    source = input_path.read_text()

    source = replace_once(
        source,
        'const std = @import("../../std.zig");',
        'const std = @import("std");',
        "public std import",
    )

    source = replace_once(
        source,
        "    var handshake_state: HandshakeState = .hello;\n",
        "    var handshake_state: HandshakeState = .hello;\n"
        "    // Bongo Zig-0.16 backport: remember whether the server requested a\n"
        "    // client certificate. Bongo has no client certificate configured,\n"
        "    // so the protocol-correct response is an empty Certificate message.\n"
        "    var server_requested_client_certificate = false;\n",
        "certificate request state",
    )

    marker = """                        handshake_state = .certificate;
                    },
                    .certificate => cert: {
"""
    certificate_request_case = """                        handshake_state = .certificate;
                    },
                    .certificate_request => {
                        switch (tls_version) {
                            .tls_1_3 => {
                                if (cipher_state != .handshake) return error.TlsUnexpectedMessage;
                                if (handshake_state != .certificate) return error.TlsUnexpectedMessage;
                                try hsd.ensure(1);
                                const context_len = hsd.decode(u8);
                                // A CertificateRequest in the initial TLS 1.3 handshake
                                // must use an empty request context. Non-empty contexts are
                                // reserved for post-handshake authentication, which this
                                // Zig 0.16 backport does not implement.
                                if (context_len != 0) return error.TlsIllegalParameter;
                                try hsd.ensure(2);
                                const extensions_len = hsd.decode(u16);
                                _ = try hsd.sub(extensions_len);
                            },
                            .tls_1_2 => {
                                if (cipher_state != .cleartext) return error.TlsUnexpectedMessage;
                                if (handshake_state != .server_hello_done) return error.TlsUnexpectedMessage;
                                try hsd.ensure(1);
                                const certificate_types_len = hsd.decode(u8);
                                try hsd.ensure(certificate_types_len + 2);
                                hsd.skip(certificate_types_len);
                                const signature_algorithms_len = hsd.decode(u16);
                                try hsd.ensure(signature_algorithms_len + 2);
                                hsd.skip(signature_algorithms_len);
                                const certificate_authorities_len = hsd.decode(u16);
                                try hsd.ensure(certificate_authorities_len);
                                hsd.skip(certificate_authorities_len);
                            },
                            else => return error.TlsUnexpectedMessage,
                        }
                        switch (handshake_cipher) {
                            inline else => |*p| p.transcript_hash.update(wrapped_handshake),
                        }
                        server_requested_client_certificate = true;
                    },
                    .certificate => cert: {
"""
    source = replace_once(
        source,
        marker,
        certificate_request_case,
        "CertificateRequest handler",
    )

    tls12_public_key_marker = """                        const client_key_exchange_prefix = .{@intFromEnum(tls.ContentType.handshake)} ++
"""
    tls12_certificate_setup = """                        const client_certificate_cleartext =
                            .{@intFromEnum(tls.HandshakeType.certificate)} ++
                            int(u24, 3) ++
                            int(u24, 0);
                        const client_certificate_msg =
                            .{@intFromEnum(tls.ContentType.handshake)} ++
                            int(u16, @intFromEnum(tls.ProtocolVersion.tls_1_2)) ++
                            array(u16, u8, client_certificate_cleartext);

                        const client_key_exchange_prefix = .{@intFromEnum(tls.ContentType.handshake)} ++
"""
    source = replace_once(
        source,
        tls12_public_key_marker,
        tls12_certificate_setup,
        "TLS 1.2 empty Certificate setup",
    )

    tls12_transcript_old = """                                p.transcript_hash.update(wrapped_handshake);
                                p.transcript_hash.update(client_key_exchange_prefix[tls.record_header_len..]);
                                p.transcript_hash.update(public_key_bytes);
"""
    tls12_transcript_new = """                                p.transcript_hash.update(wrapped_handshake);
                                if (server_requested_client_certificate) {
                                    p.transcript_hash.update(&client_certificate_cleartext);
                                }
                                p.transcript_hash.update(client_key_exchange_prefix[tls.record_header_len..]);
                                p.transcript_hash.update(public_key_bytes);
"""
    source = replace_once(
        source,
        tls12_transcript_old,
        tls12_transcript_new,
        "TLS 1.2 transcript",
    )

    tls12_output_old = """                                var all_msgs_vec: [4][]const u8 = .{
                                    &client_key_exchange_prefix,
                                    public_key_bytes,
                                    &client_change_cipher_spec_msg,
                                    &client_verify_msg,
                                };
                                try output.writeVecAll(&all_msgs_vec);
"""
    tls12_output_new = """                                var all_msgs_vec: [5][]const u8 = .{
                                    &client_certificate_msg,
                                    &client_key_exchange_prefix,
                                    public_key_bytes,
                                    &client_change_cipher_spec_msg,
                                    &client_verify_msg,
                                };
                                const first_message: usize = if (server_requested_client_certificate) 0 else 1;
                                try output.writeVecAll(all_msgs_vec[first_message..]);
"""
    source = replace_once(
        source,
        tls12_output_old,
        tls12_output_new,
        "TLS 1.2 output",
    )

    tls13_pattern = re.compile(
        r"                                    const handshake_hash = p\.transcript_hash\.finalResult\(\);\n"
        r".*?"
        r"                                    try output\.flush\(\);\n",
        re.DOTALL,
    )
    match = tls13_pattern.search(source)
    if match is None:
        raise SystemExit("TLS 1.3 Finished block: match not found")
    if tls13_pattern.search(source, match.end()) is not None:
        raise SystemExit("TLS 1.3 Finished block: multiple matches")

    tls13_replacement = """                                    // Application traffic secrets are based on the transcript
                                    // through the server Finished. Client authentication messages
                                    // are included in the client Finished calculation but not this
                                    // application-traffic transcript point.
                                    const application_handshake_hash = p.transcript_hash.peek();
                                    const empty_client_certificate =
                                        .{@intFromEnum(tls.HandshakeType.certificate)} ++
                                        int(u24, 4) ++
                                        .{@as(u8, 0)} ++ // certificate_request_context length
                                        int(u24, 0); // empty certificate_list
                                    if (server_requested_client_certificate) {
                                        p.transcript_hash.update(&empty_client_certificate);
                                    }
                                    const client_finished_hash = p.transcript_hash.peek();
                                    const verify_data = tls.hmac(P.Hmac, &client_finished_hash, pv.client_finished_key);
                                    const client_finished = .{@intFromEnum(tls.HandshakeType.finished)} ++
                                        array(u24, u8, verify_data);

                                    if (server_requested_client_certificate) {
                                        const out_cleartext = empty_client_certificate ++
                                            client_finished ++
                                            .{@intFromEnum(tls.ContentType.handshake)};
                                        const wrapped_len = out_cleartext.len + P.AEAD.tag_length;
                                        var finished_msg = .{@intFromEnum(tls.ContentType.application_data)} ++
                                            int(u16, @intFromEnum(tls.ProtocolVersion.tls_1_2)) ++
                                            array(u16, u8, @as([wrapped_len]u8, undefined));
                                        const ad = finished_msg[0..tls.record_header_len];
                                        const ciphertext = finished_msg[tls.record_header_len..][0..out_cleartext.len];
                                        const auth_tag = finished_msg[finished_msg.len - P.AEAD.tag_length ..];
                                        const nonce = pv.client_handshake_iv;
                                        P.AEAD.encrypt(ciphertext, auth_tag, &out_cleartext, ad, nonce, pv.client_handshake_key);
                                        var all_msgs_vec: [2][]const u8 = .{
                                            &client_change_cipher_spec_msg,
                                            &finished_msg,
                                        };
                                        try output.writeVecAll(&all_msgs_vec);
                                    } else {
                                        const out_cleartext = client_finished ++
                                            .{@intFromEnum(tls.ContentType.handshake)};
                                        const wrapped_len = out_cleartext.len + P.AEAD.tag_length;
                                        var finished_msg = .{@intFromEnum(tls.ContentType.application_data)} ++
                                            int(u16, @intFromEnum(tls.ProtocolVersion.tls_1_2)) ++
                                            array(u16, u8, @as([wrapped_len]u8, undefined));
                                        const ad = finished_msg[0..tls.record_header_len];
                                        const ciphertext = finished_msg[tls.record_header_len..][0..out_cleartext.len];
                                        const auth_tag = finished_msg[finished_msg.len - P.AEAD.tag_length ..];
                                        const nonce = pv.client_handshake_iv;
                                        P.AEAD.encrypt(ciphertext, auth_tag, &out_cleartext, ad, nonce, pv.client_handshake_key);
                                        var all_msgs_vec: [2][]const u8 = .{
                                            &client_change_cipher_spec_msg,
                                            &finished_msg,
                                        };
                                        try output.writeVecAll(&all_msgs_vec);
                                    }
                                    try output.flush();
"""
    source = source[: match.start()] + tls13_replacement + source[match.end() :]

    # The application traffic secret derivation immediately after the replaced
    # block must use the transcript through server Finished.
    old_secret = '"c ap traffic", &handshake_hash, P.Hash.digest_length'
    new_secret = '"c ap traffic", &application_handshake_hash, P.Hash.digest_length'
    source = replace_once(source, old_secret, new_secret, "client application secret")
    old_secret = '"s ap traffic", &handshake_hash, P.Hash.digest_length'
    new_secret = '"s ap traffic", &application_handshake_hash, P.Hash.digest_length'
    source = replace_once(source, old_secret, new_secret, "server application secret")

    notice = """// GENERATED FILE — DO NOT EDIT DIRECTLY.\n//\n// Derived from Zig 0.16.0 lib/std/crypto/tls/Client.zig (MIT/Expat).\n// Bongo compatibility patch: protocol-correct empty client Certificate\n// responses for TLS 1.2/1.3 CertificateRequest. See:\n// docs/zig-0.16-tls-gap.md and tools/vendor_zig_0_16_tls_client.py.\n\n"""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(notice + source)


if __name__ == "__main__":
    main()
