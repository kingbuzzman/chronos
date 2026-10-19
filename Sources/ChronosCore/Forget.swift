/// Edits the viewer makes to what the recorder wrote. The recorder keeps writing meanwhile, so each is one statement:
/// SQLite runs it whole, between the recorder's writes.
package enum Forget {
    package struct OutdatedError: Error, CustomStringConvertible {
        package var description: String {
            "The database is from an older version of Chronos. Open Chronos to update it, then try again."
        }
    }

    /// Clears a site's name from every slot of the browser it was recorded in, over all time, not just the period on
    /// screen. Its time stays, as "Not identified". Visiting the site again records it again.
    package static func site(_ domain: String, in bundleID: String, _ database: Database) throws {
        // The statement is written for the latest schema; the recorder migrates when it starts, the viewer never does.
        let version = try database.userVersion
        guard version <= Schema.migrations.count else {
            throw Schema.TooNewError(found: version, supported: Schema.migrations.count)
        }
        guard version == Schema.migrations.count else { throw OutdatedError() }
        try database.run(
            "UPDATE slots SET domain = '' WHERE domain = ?1 AND app_id = (SELECT id FROM apps WHERE bundle_id = ?2)",
            [.text(domain), .text(bundleID)]
        )
    }
}
