# Access the private Journal directly from Web

The Web Workspace uses CloudKit JS and the Journal Owner's authenticated session to read and write the same private CloudKit database used by iPhone. A lightweight Support Service may perform protected AI or export work, but it does not proxy every Journal operation or retain a second canonical copy; this preserves one source of truth and uses CloudKit change tags for Revision Guards and conflict detection.
