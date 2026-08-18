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
    _ = @import("integration/14_replace_one.zig");
    _ = @import("integration/15_find_one_and_update.zig");
    _ = @import("integration/16_find_one_and_replace.zig");
    _ = @import("integration/17_find_one_and_delete.zig");
    _ = @import("integration/18_count_documents.zig");
    _ = @import("integration/19_estimated_document_count.zig");
    _ = @import("integration/20_distinct.zig");
    _ = @import("integration/21_bulk_write.zig");
}
