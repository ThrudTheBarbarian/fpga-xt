--
-- SQL schema for the desktop registry
--
-- Version 		: 1.0
-- Creation date: 2/Jul/2026
--



-- ---------------------------------------------------------------------------
-- Icon-types table
--
-- We can have different icon-types as listed below. Note these are distinct
-- actual types of icons, not just matches to wildcards
--
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS iconTypes;
CREATE TABLE iconTypes
	(
	id 			INTEGER PRIMARY KEY AUTOINCREMENT,
	type		VARCHAR NOT NULL
	);

INSERT INTO iconTypes (id,type) VALUES (1, '8-bit emulator');
INSERT INTO iconTypes (id,type) VALUES (2, '16/32-bit emulator');
INSERT INTO iconTypes (id,type) VALUES (3, '8-bit media');
INSERT INTO iconTypes (id,type) VALUES (4, '16/32-bit media');
INSERT INTO iconTypes (id,type) VALUES (5, 'Bin');
INSERT INTO iconTypes (id,type) VALUES (6, 'Folder');
INSERT INTO iconTypes (id,type) VALUES (7, 'File');
INSERT INTO iconTypes (id,type) VALUES (8, 'Fujinet');
INSERT INTO iconTypes (id,type) VALUES (9, 'Server');
INSERT INTO iconTypes (id,type) VALUES (10, 'Add Server');

-- ---------------------------------------------------------------------------
-- Window icons table
--
-- Specify a set of icon matchings for a given set of icon types
--
-- id				: used to identify the row
-- path				: path relative to /OS/Icons, or absolute path if starts
--                    with '/'
-- type 			: one of the types from the iconTypes table
-- match			: a pattern-match string, character wildcards can be
--                    represented by '%' and string wildcards can be 
--                    represented by '*', so "*.prg" means any program with a
--                    filename extension of "prg"
-- displayName		: What to display under the icon. Defaults to the filename
--                    if 'DisplayName' is NULL or empty-string
--
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS windowIcons;
CREATE TABLE windowIcons 
	(
	id 			INTEGER PRIMARY KEY AUTOINCREMENT,
	path		VARCHAR NOT NULL,
	type		INTEGER NOT NULL,
	match		VARCHAR NOT NULL DEFAULT '*',
	displayName	VARCHAR 
	);

INSERT INTO windowIcons (id,path,type,match,displayName) 
    VALUES(1,'mimetypes/crystal-style/text-x-plain.pam',7,'*',NULL);
INSERT INTO windowIcons (id,path,type,match,displayName) 
    VALUES(2,'places/crystal_clear-style/folder-blue.pam',6,'*',NULL);
INSERT INTO windowIcons (path,type,match,displayName) 
    VALUES('games/despatchRider.pam',7,'DespatchRider.atr','Despatch Rider');
INSERT INTO windowIcons (path,type,match,displayName) 
    VALUES('games/elektraglide.pam',7,'ElektraGlide.atr','Elektraglide');
INSERT INTO windowIcons (path,type,match,displayName) 
    VALUES('games/ballBlazer.pam',7,'BallBlazer.atx','Ball Blazer');
INSERT INTO windowIcons (path,type,match,displayName) 
    VALUES('actions/document-open-remote.pam',9,'Server','Server');
INSERT INTO windowIcons (path,type,match,displayName) 
    VALUES('actions/folder-new-7.pam',10,'Add server','Add server');

-- ---------------------------------------------------------------------------
-- Desktop-icons table
--
-- These are icons that inhabit the desktop level
--
-- id				: used to identify the row
-- x,y				: position on screen
-- type 			: one of the types from the iconTypes table
-- path				: path relative to /OS/Icons, or absolute path if starts
--                    with '/'
-- displayName		: What to display under the icon. Defaults to the filename
--                    if 'DisplayName' is NULL or empty-string
--
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS desktopIcons;
CREATE TABLE desktopIcons
	(
	id 			INTEGER PRIMARY KEY AUTOINCREMENT,
	x			INTEGER NOT NULL DEFAULT 10,
	y			INTEGER NOT NULL DEFAULT 10,
	type		INTEGER NOT NULL,
	path		VARCHAR NOT NULL,
	displayName	VARCHAR
	);

-- Set up the XL/XE
INSERT INTO desktopIcons (id,x,y,type,path,displayName)
	VALUES (1, 20,  980, 1, 'retro/xe.pam', '6502');
INSERT INTO desktopIcons (id,x,y,type,path,displayName)
	VALUES (2, 20,  20, 3, 'retro/floppy525.pam', '8-bit files');

INSERT INTO desktopIcons (id,x,y,type,path,displayName)
	VALUES (3, 120, 980, 2, 'retro/st.pam', 'm68k');
INSERT INTO desktopIcons (id,x,y,type,path,displayName)
	VALUES (4, 20,  120, 4, 'retro/floppy35.pam', '16-bit files');
INSERT INTO desktopIcons (id,x,y,type,path,displayName)
	VALUES (5, 20,  220, 8, 'devices/network-nfs.pam', 'Fujinet');


-- ---------------------------------------------------------------------------
-- Fujinet networking
--
-- Implement a cached networked filesystem that is browseable and extendable
-- by the user
--
-- id				: used to identify the row
-- displayName		: the editable name of the server, if null == host
-- host				: the DNS name of the server
-- port				: the port number to use
-- transport 		: one of the types from the fujiTransport table
-- path				: initial path to 'cd' into, defaults to '/'
--
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS fujiTransport;
CREATE TABLE fujiTransport
	(
	id 			INTEGER PRIMARY KEY AUTOINCREMENT,
	type		VARCHAR NOT NULL
	);

INSERT INTO fujiTransport (id,type) VALUES (1,'udp');
INSERT INTO fujiTransport (id,type) VALUES (2,'tcp');
INSERT INTO fujiTransport (id,type) VALUES (3,'auto');



DROP TABLE IF EXISTS fujiCacheState;
CREATE TABLE fujiCacheState
    (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    type           VARCHAR NOT NULL
    );

INSERT INTO fujiCacheState (id,type) VALUES (1,'fetching');
INSERT INTO fujiCacheState (id,type) VALUES (2,'cached');
INSERT INTO fujiCacheState (id,type) VALUES (3,'updateAvailable');



DROP TABLE IF EXISTS fujiCache;
CREATE TABLE fujiCache
    (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    server         INTEGER NOT NULL, -- ref to fujinet:id
    remotePath     VARCHAR NOT NULL,
    state          INTEGER NOT NULL DEFAULT 1,  -- ref to fujiCacheState:id
    size           INTEGER,
    remoteMtime    INTEGER,
    fetchedAt      INTEGER,
    UNIQUE(server, remotePath)
    );
    
    
    
DROP TABLE IF EXISTS fujinet;
CREATE TABLE fujinet
	(
	id 			INTEGER PRIMARY KEY AUTOINCREMENT,
	displayName	VARCHAR,
	host 		VARCHAR NOT NULL,
	port		INTEGER NOT NULL DEFAULT 16384,
	transport	INTEGER NOT NULL DEFAULT 3,  -- ref to fujiTransport:id
	path		VARCHAR NOT NULL DEFAULT '/'
	);



-- ---------------------------------------------------------------------------
-- Desktop menus, views and sorting
--
-- contextMenu drives the right-click menu, scoped by where the click landed
-- (desktop / drive / in-window / icon-in-window). Users add/delete rows to
-- customise it; every item carries an accelerator. `action` is a verb the
-- desktop dispatches; `label` "-" is a separator; a `submenu` name groups
-- child items (e.g. the Show submenu). viewMode/sortMode + deskPrefs hold the
-- view defaults (per-window state overrides these live).
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS menuScope;
CREATE TABLE menuScope
    (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    type    VARCHAR NOT NULL
    );
INSERT INTO menuScope (id,type) VALUES (1,'desktop');
INSERT INTO menuScope (id,type) VALUES (2,'drive');
INSERT INTO menuScope (id,type) VALUES (3,'window');
INSERT INTO menuScope (id,type) VALUES (4,'icon');

DROP TABLE IF EXISTS viewMode;
CREATE TABLE viewMode
    (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    type    VARCHAR NOT NULL
    );
INSERT INTO viewMode (id,type) VALUES (1,'icons');
INSERT INTO viewMode (id,type) VALUES (2,'single');
INSERT INTO viewMode (id,type) VALUES (3,'multi');

DROP TABLE IF EXISTS sortMode;
CREATE TABLE sortMode
    (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    type    VARCHAR NOT NULL
    );
INSERT INTO sortMode (id,type) VALUES (1,'unsorted');
INSERT INTO sortMode (id,type) VALUES (2,'name');
INSERT INTO sortMode (id,type) VALUES (3,'type');
INSERT INTO sortMode (id,type) VALUES (4,'size');
INSERT INTO sortMode (id,type) VALUES (5,'date');

DROP TABLE IF EXISTS contextMenu;
CREATE TABLE contextMenu
    (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    scope   INTEGER NOT NULL,               -- ref menuScope:id
    ord     INTEGER NOT NULL DEFAULT 0,     -- display order within the scope
    label   VARCHAR NOT NULL,               -- text; "-" = separator
    accel   VARCHAR,                        -- e.g. "^N" or a mnemonic letter
    action  VARCHAR NOT NULL,               -- verb the desktop dispatches
    submenu VARCHAR                         -- non-null: this item opens a submenu
    );
-- in-window (scope 3) starter set
INSERT INTO contextMenu (scope,ord,label,accel,action,submenu) VALUES (3,10,'New...','^N','new',NULL);
INSERT INTO contextMenu (scope,ord,label,accel,action,submenu) VALUES (3,20,'Info...','^I','info',NULL);
INSERT INTO contextMenu (scope,ord,label,accel,action,submenu) VALUES (3,30,'Select all','^A','selectall',NULL);
INSERT INTO contextMenu (scope,ord,label,accel,action,submenu) VALUES (3,40,'Delete','^D','delete',NULL);
INSERT INTO contextMenu (scope,ord,label,accel,action,submenu) VALUES (3,50,'-',NULL,'sep',NULL);
INSERT INTO contextMenu (scope,ord,label,accel,action,submenu) VALUES (3,60,'Show','^S','show','show');
INSERT INTO contextMenu (scope,ord,label,accel,action,submenu) VALUES (3,70,'Browse','^B','browse',NULL);
-- desktop (scope 1) starter set
INSERT INTO contextMenu (scope,ord,label,accel,action,submenu) VALUES (1,10,'New...','^N','new',NULL);
INSERT INTO contextMenu (scope,ord,label,accel,action,submenu) VALUES (1,20,'Info...','^I','info',NULL);
INSERT INTO contextMenu (scope,ord,label,accel,action,submenu) VALUES (1,30,'Browse','^B','browse',NULL);
-- icon (scope 4) starter set
INSERT INTO contextMenu (scope,ord,label,accel,action,submenu) VALUES (4,10,'Open','^O','open',NULL);
INSERT INTO contextMenu (scope,ord,label,accel,action,submenu) VALUES (4,20,'Info...','^I','info',NULL);
INSERT INTO contextMenu (scope,ord,label,accel,action,submenu) VALUES (4,30,'Delete','^D','delete',NULL);

DROP TABLE IF EXISTS deskPrefs;
CREATE TABLE deskPrefs
    (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    key     VARCHAR NOT NULL UNIQUE,
    value   VARCHAR NOT NULL
    );
INSERT INTO deskPrefs (key,value) VALUES ('viewMode','1');       -- ref viewMode:id (icons)
INSERT INTO deskPrefs (key,value) VALUES ('sortMode','2');       -- ref sortMode:id (name)
INSERT INTO deskPrefs (key,value) VALUES ('sortInverted','0');
INSERT INTO deskPrefs (key,value) VALUES ('columns','size,date'); -- multi/text column attrs
