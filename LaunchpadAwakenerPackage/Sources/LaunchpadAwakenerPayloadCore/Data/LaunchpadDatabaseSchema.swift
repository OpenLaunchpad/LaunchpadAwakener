import Foundation

/// The layout database format of macOS 15's Launchpad (schema version 13), which this store keeps.
///
/// Items form one tree in the `items` table: the root, its pages, the applications and folders on
/// each page, and each folder's own pages. The triggers are macOS 15's own: inserting an item appends
/// it to its parent, changing `ordering` shifts its siblings, changing `parent_id` moves it to the end
/// of the new parent, and deleting closes the gap. Code that writes here relies on them.
package enum LaunchpadDatabaseSchema {
    /// The `items.type` values.
    package enum ItemType: Int64, Sendable {
        case root = 1
        case folder = 2
        case page = 3
        case application = 4
        case downloadingApplication = 5
    }

    package static let version = 13

    /// Prefix of the invisible pages macOS 15 parked unplaced items on (`HOLDINGPAGE`,
    /// `HOLDINGPAGE_DB`, `HOLDINGPAGE_VERS`). They are never shown.
    package static let holdingPageIdentifierPrefix = "HOLDINGPAGE"

    package static let rootPageIdentifier = "ROOTPAGE"

    /// `dbinfo` keys.
    package enum InformationKey {
        package static let ignoreItemUpdateTriggers = "ignore_items_update_triggers"
        package static let launchpadRoot = "launchpad_root"
        package static let version = "version"
        /// Ours: where the layout came from the first time — `legacy` or `discovery`.
        package static let layoutOrigin = "LaunchpadAwakenerLayoutOrigin"
    }

    /// Copied from a macOS 15 database's `.schema`, statement for statement.
    package static let creationStatements = """
        CREATE TABLE dbinfo (key VARCHAR, value VARCHAR);
        CREATE TABLE items (rowid INTEGER PRIMARY KEY ASC, uuid VARCHAR, flags INTEGER, type INTEGER, parent_id INTEGER NOT NULL, ordering INTEGER);
        CREATE TABLE apps (item_id INTEGER PRIMARY KEY, title VARCHAR, bundleid VARCHAR, storeid VARCHAR,category_id INTEGER, moddate REAL, bookmark BLOB);
        CREATE TABLE groups (item_id INTEGER PRIMARY KEY, category_id INTEGER, title VARCHAR);
        CREATE TABLE downloading_apps (item_id INTEGER PRIMARY KEY, title VARCHAR, bundleid VARCHAR, storeid VARCHAR, category_id INTEGER, install_path VARCHAR);
        CREATE TABLE categories (rowid INTEGER PRIMARY KEY ASC, uti VARCHAR);
        CREATE TABLE app_sources (rowid INTEGER PRIMARY KEY ASC, uuid VARCHAR, flags INTEGER, bookmark BLOB, last_fsevent_id INTEGER, fsevent_uuid VARCHAR);
        CREATE TABLE image_cache (item_id INTEGER, size_big INTEGER, size_mini INTEGER, image_data BLOB, image_data_mini BLOB);
        CREATE TRIGGER update_items_order BEFORE UPDATE OF ordering ON items WHEN new.ordering > old.ordering AND 0 == (SELECT value FROM dbinfo WHERE key='ignore_items_update_triggers')
        BEGIN
        	UPDATE dbinfo SET value=1 WHERE key='ignore_items_update_triggers';
        	UPDATE items SET ordering = ordering - 1 WHERE parent_id = old.parent_id AND ordering BETWEEN old.ordering and new.ordering;
        	UPDATE dbinfo SET value=0 WHERE key='ignore_items_update_triggers';
        END;
        CREATE TRIGGER update_items_order_backwards BEFORE UPDATE OF ordering ON items WHEN new.ordering < old.ordering AND 0 == (SELECT value FROM dbinfo WHERE key='ignore_items_update_triggers')
        BEGIN
        	UPDATE dbinfo SET value=1 WHERE key='ignore_items_update_triggers';
        	UPDATE items SET ordering = ordering + 1 WHERE parent_id = old.parent_id AND ordering BETWEEN new.ordering and old.ordering;
        	UPDATE dbinfo SET value=0 WHERE key='ignore_items_update_triggers';
        END;
        CREATE TRIGGER update_item_parent AFTER UPDATE OF parent_id ON items WHEN 0 == (SELECT value FROM dbinfo WHERE key='ignore_items_update_triggers')
        BEGIN
        	UPDATE dbinfo SET value=1 WHERE key='ignore_items_update_triggers';
        	UPDATE items SET ordering = (SELECT ifnull(MAX(ordering),0)+1 FROM items WHERE parent_id=new.parent_id AND ROWID!=old.rowid) WHERE ROWID=old.rowid;
        	UPDATE items SET ordering = ordering - 1 WHERE parent_id = old.parent_id and ordering > old.ordering;
        	UPDATE dbinfo SET value=0 WHERE key='ignore_items_update_triggers';
        END;
        CREATE TRIGGER insert_item AFTER INSERT on items WHEN 0 == (SELECT value FROM dbinfo WHERE key='ignore_items_update_triggers')
        BEGIN
        	UPDATE dbinfo SET value=1 WHERE key='ignore_items_update_triggers';
        	UPDATE items SET ordering = (SELECT ifnull(MAX(ordering),0)+1 FROM items WHERE parent_id=new.parent_id) WHERE ROWID=new.rowid;
        	UPDATE dbinfo SET value=0 WHERE key='ignore_items_update_triggers';
        END;
        CREATE TRIGGER app_inserted AFTER INSERT ON items WHEN new.type = 4 OR new.type = 5
        BEGIN
        	INSERT INTO image_cache VALUES (new.rowid,0,0,NULL,NULL);
        END;
        CREATE TRIGGER app_deleted AFTER DELETE ON items WHEN old.type = 4 OR old.type = 5
        BEGIN
        	DELETE FROM image_cache WHERE item_id=old.rowid;
        END;
        CREATE TRIGGER item_deleted AFTER DELETE ON items
        BEGIN
        	DELETE FROM apps WHERE rowid=old.rowid;
        	DELETE FROM groups WHERE item_id=old.rowid;
        	DELETE FROM downloading_apps WHERE item_id=old.rowid;
        	UPDATE dbinfo SET value=1 WHERE key='ignore_items_update_triggers';
        	UPDATE items SET ordering = ordering - 1 WHERE old.parent_id = parent_id AND ordering > old.ordering;
        	UPDATE dbinfo SET value=0 WHERE key='ignore_items_update_triggers';
        END;
        CREATE INDEX items_uuid_index ON items (uuid);
        CREATE INDEX items_ordering_index ON items (parent_id,ordering);
        CREATE INDEX items_type ON items (type);
        CREATE INDEX image_cache_index ON image_cache (item_id);
        """
}
