# Make the Web Workspace online-first

The first Web Workspace requires connectivity for canonical reads, synchronization, activation, and publication, while locally buffering unfinished Plan and Review drafts against transient connection loss. Full offline replication is reserved for the iPhone execution surface because adding a second offline database and mutation queue would substantially increase synchronization complexity without supporting the Web Workspace's primary planning and reflection role.
