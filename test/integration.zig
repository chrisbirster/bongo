test {
    _ = @import("integration/01_connection.zig");
    _ = @import("integration/02_hello.zig");
    _ = @import("integration/03_find_requires_auth.zig");
    _ = @import("integration/04_authenticate.zig");
    _ = @import("integration/05_client_find.zig");
    _ = @import("integration/06_cursor.zig");
    _ = @import("integration/07_insert_one.zig");
    _ = @import("integration/08_update_one.zig");
    _ = @import("integration/09_delete_one.zig");
    _ = @import("integration/10_find_one.zig");
    _ = @import("integration/11_insert_many.zig");
    _ = @import("integration/12_update_many.zig");
    _ = @import("integration/13_delete_many.zig");
}
