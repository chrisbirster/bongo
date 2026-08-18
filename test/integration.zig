test {
    _ = @import("integration/01_connection.zig");
    _ = @import("integration/02_hello.zig");
    _ = @import("integration/03_find_requires_auth.zig");
    _ = @import("integration/04_authenticate.zig");
}
