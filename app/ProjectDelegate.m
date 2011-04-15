#import "ProjectDelegate.h"
#import "logging.h"
#import "MHTextIconCell.h"
#import "SFTPConnectionPool.h"
#import "ViWindowController.h"
#import "ExEnvironment.h"
#import "ViError.h"
#import "NSString-additions.h"
#import "ViDocumentController.h"

@interface ProjectDelegate (private)
+ (NSMutableArray *)childrenAtURL:(NSURL *)url error:(NSError **)outError;
+ (NSMutableArray *)childrenAtFileURL:(NSURL *)url error:(NSError **)outError;
+ (NSMutableArray *)childrenAtSftpURL:(NSURL *)url error:(NSError **)outError;
+ (void)recursivelySortProjectFiles:(NSMutableArray *)children;
- (NSString *)relativePathForItem:(NSDictionary *)item;
- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item;
- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item;
- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)anIndex ofItem:(id)item;
- (void)expandNextItem:(id)dummy;
- (void)expandItems:(NSArray *)items recursionLimit:(int)recursionLimit;
+ (NSMutableArray *)sortProjectFiles:(NSMutableArray *)children;
- (BOOL)rescan_files:(ViCommand *)command;
@end

@implementation ProjectFile

@synthesize score, markedString, url;

- (id)initWithURL:(NSURL *)aURL
{
	self = [super init];
	if (self) {
		url = aURL;
	}
	return self;
}

- (id)initWithURL:(NSURL *)aURL entry:(SFTPDirectoryEntry *)anEntry
{
	self = [super init];
	if (self) {
		url = aURL;
		entry = anEntry;
	}
	return self;
}

+ (id)fileWithURL:(NSURL *)aURL
{
	return [[ProjectFile alloc] initWithURL:aURL];
}

+ (id)fileWithURL:(NSURL *)aURL sftpInfo:(SFTPDirectoryEntry *)entry
{
	return [[ProjectFile alloc] initWithURL:aURL entry:entry];
}

- (BOOL)isDirectory
{
	if ([url isFileURL]) {
		BOOL isDirectory = NO;
		if ([[NSFileManager defaultManager] fileExistsAtPath:[url path]
							 isDirectory:&isDirectory] && isDirectory)
			return YES;
		return NO;
	} else {
		return [entry isDirectory];
	}
}

- (NSMutableArray *)children
{
	if (children == nil && [self isDirectory]) {
		NSError *error = nil;
		children = [ProjectDelegate childrenAtURL:url error:&error];
		if (error)
			INFO(@"error: %@", [error localizedDescription]);
	}
	return children;
}

- (BOOL)hasCachedChildren
{
	return children != nil;
}

- (NSString *)name
{
	if ([url isFileURL]) {
		return [[NSFileManager defaultManager] displayNameAtPath:[url path]];
	} else
		return [url lastPathComponent];
}

- (NSString *)pathRelativeToURL:(NSURL *)relURL
{
        NSString *root = [relURL path];
        NSString *path = [url path];
        if ([path length] > [root length]) {
                NSRange r = NSMakeRange([root length] + 1,
                    [path length] - [root length] - 1);
                return [path substringWithRange:r];
	}
        return path;
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<ProjectFile: %@>", url];
}

@end

@implementation ProjectDelegate

@synthesize delegate;

- (id)init
{
	self = [super init];
	if (self) {
		NSString *skipPattern = [[NSUserDefaults standardUserDefaults] stringForKey:@"skipPattern"];
		skipRegex = [[ViRegexp alloc] initWithString:skipPattern];
		matchParagraphStyle = [[NSParagraphStyle defaultParagraphStyle] mutableCopy];
		[matchParagraphStyle setLineBreakMode:NSLineBreakByTruncatingHead];
	}
	return self;
}

- (void)awakeFromNib
{
	explorer.keyManager = [[ViKeyManager alloc] initWithTarget:self
							defaultMap:[ViMap explorerMap]];
	[explorer setTarget:self];
	[explorer setDoubleAction:@selector(explorerDoubleClick:)];
	[explorer setAction:@selector(explorerClick:)];
	[[sftpConnectForm cellAtIndex:1] setPlaceholderString:NSUserName()];
	[rootButton setTarget:self];
	[rootButton setAction:@selector(changeRoot:)];
	[actionButtonCell setImage:[NSImage imageNamed:@"actionmenu"]];
	[actionButton setMenu:actionMenu];

	[[NSUserDefaults standardUserDefaults] addObserver:self
						forKeyPath:@"explorecaseignore"
						   options:NSKeyValueObservingOptionNew
						   context:NULL];
	[[NSUserDefaults standardUserDefaults] addObserver:self
						forKeyPath:@"exploresortfolders"
						   options:NSKeyValueObservingOptionNew
						   context:NULL];

	[self browseURL:[environment baseURL]];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
		      ofObject:(id)object
			change:(NSDictionary *)change
		       context:(void *)context
{
	/* only explorecaseignore and exploresortfolders options observed */
	/* re-sort explorer */
	if (rootItems) {
		[ProjectDelegate recursivelySortProjectFiles:rootItems];
		if (!isFiltered)
			[self filterFiles:self];
	}
}

- (BOOL)control:(NSControl *)control textShouldEndEditing:(NSText *)fieldEditor
{
	if (control == explorer) {
		NSInteger idx = [explorer editedRow];
		ProjectFile *file = [explorer itemAtRow:idx];
		NSURL *newurl = [NSURL URLWithString:[fieldEditor string]
				       relativeToURL:[file url]];
		NSError *error = nil;
		if ([[file url] isFileURL]) {
			[[NSFileManager defaultManager] moveItemAtURL:[file url]
							        toURL:newurl
							        error:&error];
		} else {
			SFTPConnection *conn = [[SFTPConnectionPool sharedPool]
			    connectionWithURL:[file url] error:&error];
			[conn renameItemAtPath:[[file url] path]
				        toPath:[newurl path]
					 error:&error];
		}

		if (error != nil)
			[NSApp presentError:error];
		else {
			ViDocument *doc = [windowController documentForURL:[file url]];
			[file setUrl:newurl];
			[doc setFileURL:newurl];
		}
	}
	return YES;
}

- (void)changeRoot:(id)sender
{
	[self browseURL:[[sender clickedPathComponentCell] URL]];
}

+ (NSMutableArray *)childrenAtURL:(NSURL *)url error:(NSError **)outError
{
	if ([url isFileURL])
		return [self childrenAtFileURL:url error:outError];
	else if ([[url scheme] isEqualToString:@"sftp"])
		return [self childrenAtSftpURL:url error:outError];
	else if (outError)
		*outError = [ViError errorWithFormat:@"unhandled scheme %@", [url scheme]];
	return nil;
}

+ (NSMutableArray *)sortProjectFiles:(NSMutableArray *)children
{
	BOOL sortFolders = [[NSUserDefaults standardUserDefaults] boolForKey:@"exploresortfolders"];
	BOOL caseIgnoreSort = [[NSUserDefaults standardUserDefaults] boolForKey:@"explorecaseignore"];

	NSStringCompareOptions sortOptions = 0;
	if (caseIgnoreSort)
		sortOptions = NSCaseInsensitiveSearch;

	[children sortUsingComparator:^(id obj1, id obj2) {
		if (sortFolders) {
			if ([obj1 isDirectory]) {
				if (![obj2 isDirectory])
					return (NSComparisonResult)NSOrderedAscending;
			} else if ([obj2 isDirectory])
				return (NSComparisonResult)NSOrderedDescending;
		}
		return [[obj1 name] compare:[obj2 name] options:sortOptions];
	}];
	return children;
}

+ (void)recursivelySortProjectFiles:(NSMutableArray *)children
{
	[self sortProjectFiles:children];

	for (ProjectFile *file in children)
		if ([file hasCachedChildren] && [file isDirectory])
			[self recursivelySortProjectFiles:[file children]];
}

+ (NSMutableArray *)childrenAtFileURL:(NSURL *)url error:(NSError **)outError
{
	NSFileManager *fm = [NSFileManager defaultManager];

	NSArray *files = [fm contentsOfDirectoryAtPath:[url path] error:outError];
	if (files == nil)
		return nil;

	NSString *skipPattern = [[NSUserDefaults standardUserDefaults] stringForKey:@"skipPattern"];
	ViRegexp *skipRegex = [[ViRegexp alloc] initWithString:skipPattern];

	NSMutableArray *children = [[NSMutableArray alloc] init];
	for (NSString *filename in files)
		if (![filename hasPrefix:@"."] && [skipRegex matchInString:filename] == nil) {
			NSURL *curl = [url URLByAppendingPathComponent:filename];
			[children addObject:[ProjectFile fileWithURL:curl]];
		}

	return [self sortProjectFiles:children];
}

+ (NSMutableArray *)childrenAtSftpURL:(NSURL *)url error:(NSError **)outError
{
	SFTPConnection *conn = [[SFTPConnectionPool sharedPool] connectionWithURL:url error:outError];
	if (conn == nil)
		return nil;

	NSArray *entries = [conn contentsOfDirectoryAtPath:[url path] error:outError];
	if (entries == nil)
		return nil;

	NSString *skipPattern = [[NSUserDefaults standardUserDefaults] stringForKey:@"skipPattern"];
	ViRegexp *skipRegex = [[ViRegexp alloc] initWithString:skipPattern];

	NSMutableArray *children = [[NSMutableArray alloc] init];
	SFTPDirectoryEntry *entry;
	for (entry in entries) {
		NSString *filename = [entry filename];
		if (![filename hasPrefix:@"."] && [skipRegex matchInString:filename] == nil) {
			NSURL *curl = [url URLByAppendingPathComponent:filename];
			[children addObject:[ProjectFile fileWithURL:curl sftpInfo:entry]];
		}
	}

	return [self sortProjectFiles:children];
}

- (void)browseURL:(NSURL *)aURL andDisplay:(BOOL)display
{
	NSError *error = nil;
	NSMutableArray *children = nil;

	children = [ProjectDelegate childrenAtURL:aURL error:&error];

	if (children) {
		if (display)
			[self openExplorerTemporarily:NO];
		rootItems = children;
		[self filterFiles:self];
		[explorer reloadData];
		[rootButton setURL:aURL];
	} else if (error) {
		NSAlert *alert = [NSAlert alertWithError:error];
		[alert runModal];
	}

	explorer.lastSelectedRow = 0;
}

- (void)browseURL:(NSURL *)aURL
{
	[self browseURL:aURL andDisplay:YES];
}

#pragma mark -
#pragma mark Explorer actions

- (IBAction)actionMenu:(id)sender
{
	NSPoint p = NSMakePoint(0, 0);
	NSIndexSet *set = [explorer selectedRowIndexes];
	if ([set count] > 0)
		p = [explorer rectOfRow:[set firstIndex]].origin;
	NSEvent *ev = [NSEvent mouseEventWithType:NSLeftMouseDown
	                                 location:[explorer convertPoint:p toView:nil]
	                            modifierFlags:0
	                                timestamp:1
	                             windowNumber:[window windowNumber]
	                                  context:[NSGraphicsContext currentContext]
	                              eventNumber:1
	                               clickCount:1
	                                 pressure:0.0];
	[NSMenu popUpContextMenu:actionMenu withEvent:ev forView:sender];
}

- (void)openPanelDidEnd:(NSOpenPanel *)panel
             returnCode:(int)returnCode
            contextInfo:(void *)contextInfo
{
	if (returnCode == NSCancelButton)
		return;

	for (NSURL *url in [panel URLs])
		[self browseURL:url];
}

- (IBAction)addLocation:(id)sender
{
	NSOpenPanel *openPanel = [NSOpenPanel openPanel];
	[openPanel setCanChooseDirectories:YES];
	[openPanel setAllowsMultipleSelection:NO];
	[openPanel beginSheetForDirectory:nil
	                             file:nil
	                            types:nil
	                   modalForWindow:window
	                    modalDelegate:self
	                   didEndSelector:@selector(openPanelDidEnd:returnCode:contextInfo:)
	                      contextInfo:nil];
}

- (void)sftpSheetDidEnd:(NSWindow *)sheet
             returnCode:(int)returnCode
            contextInfo:(void *)contextInfo
{
	[sheet orderOut:self];
}

- (IBAction)acceptSftpSheet:(id)sender
{
	if ([[[sftpConnectForm cellAtIndex:0] stringValue] length] == 0) {
		NSBeep();
		[sftpConnectForm selectTextAtIndex:0];
		return;
	}
	[NSApp endSheet:sftpConnectView];
	NSString *host = [[sftpConnectForm cellAtIndex:0] stringValue];
	NSString *user = [[sftpConnectForm cellAtIndex:1] stringValue];	/* might be blank */
	NSString *path = [[sftpConnectForm cellAtIndex:2] stringValue];

	NSError *error = nil;
	SFTPConnection *conn = [[SFTPConnectionPool sharedPool] connectionWithHost:host
	                                                                      user:user
	                                                                     error:&error];
	if (conn) {
		if (![path hasPrefix:@"/"])
			path = [NSString stringWithFormat:@"%@/%@", [conn home], path];
		NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"sftp://%@@%@%@",
		    user, host, path]];
		[self browseURL:url];
	} else {
		NSAlert *alert = [NSAlert alertWithError:error];
		[alert runModal];
	}
}

- (IBAction)cancelSftpSheet:(id)sender
{
	[NSApp endSheet:sftpConnectView];
}

- (IBAction)addSFTPLocation:(id)sender
{
	[NSApp beginSheet:sftpConnectView
	   modalForWindow:window
	    modalDelegate:self
	   didEndSelector:@selector(sftpSheetDidEnd:returnCode:contextInfo:)
	      contextInfo:nil];
}

- (NSIndexSet *)clickedIndexes
{
	NSIndexSet *set = [explorer selectedRowIndexes];
	NSInteger clickedRow = [explorer clickedRow];
	if (clickedRow != -1 && ![set containsIndex:clickedRow])
		set = [NSIndexSet indexSetWithIndex:clickedRow];
	return set;
}

- (IBAction)openInTab:(id)sender
{
	NSIndexSet *set = [self clickedIndexes];
	[set enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
		ProjectFile *item = [explorer itemAtRow:idx];
		if (item && ![self outlineView:explorer isItemExpandable:item])
			[delegate gotoURL:[item url]];
	}];
	[self cancelExplorer];
}

- (IBAction)openInCurrentView:(id)sender
{
	NSUInteger idx = [[self clickedIndexes] firstIndex];
	ProjectFile *file = [explorer itemAtRow:idx];
	if (!file)
		return;
	ViDocument *doc = [[ViDocumentController sharedDocumentController] openDocument:[file url]
									     andDisplay:NO
									 allowDirectory:NO];
	if (doc)
		[windowController switchToDocument:doc];
	[self cancelExplorer];
}

- (IBAction)openInSplit:(id)sender
{
	NSIndexSet *set = [self clickedIndexes];
	[set enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
		ProjectFile *item = [explorer itemAtRow:idx];
		if (item && ![self outlineView:explorer isItemExpandable:item])
			[windowController splitVertically:NO
						  andOpen:[item url]
				       orSwitchToDocument:nil];
	}];
	[self cancelExplorer];
}

- (IBAction)openInVerticalSplit:(id)sender;
{
	NSIndexSet *set = [self clickedIndexes];
	[set enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
		ProjectFile *item = [explorer itemAtRow:idx];
		if (item && ![self outlineView:explorer isItemExpandable:item])
			[windowController splitVertically:YES
						  andOpen:[item url]
				       orSwitchToDocument:nil];
	}];
	[self cancelExplorer];
}

- (IBAction)renameFile:(id)sender
{
	NSIndexSet *set = [self clickedIndexes];
	if ([set count] > 1)
		return;
	[explorer selectRowIndexes:set byExtendingSelection:NO];
	[explorer editColumn:0 row:[set firstIndex] withEvent:nil select:YES];
}

- (void)removeAlertDidEnd:(NSAlert *)alert
               returnCode:(NSInteger)returnCode
              contextInfo:(void *)contextInfo
{
	if (returnCode != NSAlertFirstButtonReturn)
		return;

	NSArray *urls = contextInfo;

	BOOL isLocal = [[urls objectAtIndex:0] isFileURL];
	__block BOOL failed = NO;
	if (isLocal) {
		NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
		[workspace recycleURLs:urls completionHandler:^(NSDictionary *newURLs, NSError *error) {
			if (error != nil) {
				[NSApp presentError:error];
				failed = YES;
			}
		}];
	} else {
		for (NSURL *url in urls) {
			SFTPConnection *conn = [[SFTPConnectionPool sharedPool] connectionWithURL:url
											    error:nil];
			NSError *error = nil;
			failed = ![conn removeItemAtPath:[url path] error:&error];
			if (error) {
				[NSApp presentError:error];
				failed = YES;
			}
			if (failed)
				break;
		}
	}

	if (!failed) {
		/* Rescan containing folder(s) ? */
		[self rescan_files:nil];
	}
}

- (IBAction)removeFiles:(id)sender
{
	__block NSMutableArray *urls = [[NSMutableArray alloc] init];
	NSIndexSet *set = [self clickedIndexes];
	[set enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
		ProjectFile *item = [explorer itemAtRow:idx];
		[urls addObject:[item url]];
	}];

	if ([urls count] == 0)
		return;

	BOOL isLocal = [[urls objectAtIndex:0] isFileURL];
	char *pluralS = ([urls count] == 1 ? "" : "s");

	NSAlert *alert = [[NSAlert alloc] init];
	if (isLocal)
		[alert setMessageText:[NSString stringWithFormat:@"Do you want to move the selected file%s to the trash?", pluralS]];
	else
		[alert setMessageText:[NSString stringWithFormat:@"Do you want to permanently delete the selected file%s?", pluralS]];
	[alert addButtonWithTitle:@"OK"];
	[alert addButtonWithTitle:@"Cancel"];
	if (isLocal) {
		[alert setInformativeText:[NSString stringWithFormat:@"%lu file%s will be moved to the trash.", [urls count], pluralS]];
		[alert setAlertStyle:NSWarningAlertStyle];
	} else {
		[alert setInformativeText:[NSString stringWithFormat:@"%lu file%s will be deleted immediately. This operation cannot be undone!", [urls count], pluralS]];
		[alert setAlertStyle:NSCriticalAlertStyle];
	}

	[alert beginSheetModalForWindow:window
			  modalDelegate:self
			 didEndSelector:@selector(removeAlertDidEnd:returnCode:contextInfo:)
			    contextInfo:urls];
}

- (IBAction)rescan:(id)sender
{
	NSURL *url = [rootButton URL];
	if (![url isFileURL]) {
		/* Forget SFTP directory cache. */
		SFTPConnection *conn = [[SFTPConnectionPool sharedPool] connectionWithURL:url
										    error:nil];
		[conn flushDirectoryCache];
	}
	[self browseURL:url];
}

- (IBAction)revealInFinder:(id)sender
{
	__block NSMutableArray *urls = [[NSMutableArray alloc] init];
	NSIndexSet *set = [self clickedIndexes];
	[set enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
		ProjectFile *item = [explorer itemAtRow:idx];
		[urls addObject:[item url]];
	}];
	[[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:urls];
}

- (IBAction)openWithFinder:(id)sender
{
	NSIndexSet *set = [self clickedIndexes];
	[set enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
		ProjectFile *item = [explorer itemAtRow:idx];
		[[NSWorkspace sharedWorkspace] openURL:[item url]];
	}];
}

- (IBAction)newDocument:(id)sender
{
}

- (IBAction)newFolder:(id)sender
{
	NSIndexSet *set = [self clickedIndexes];
	NSURL *parent = nil;
	if ([set count] == 1) {
		ProjectFile *pf = [explorer itemAtRow:[set firstIndex]];
		if ([pf isDirectory])
			parent = [pf url];
		else
			parent = [[explorer parentForItem:pf] url];
	}
	if (parent == nil)
		parent = [rootButton URL];

	NSError *error = nil;
	NSString *path = [[parent path] stringByAppendingPathComponent:@"New Folder"];
	if ([parent isFileURL]) {
		NSFileManager *fm = [NSFileManager defaultManager];
		if (![fm createDirectoryAtPath:path
		   withIntermediateDirectories:NO
				    attributes:nil
					 error:&error])
			[NSApp presentError:error];
		else
			[self rescan_files:nil];
	} else {
		SFTPConnection *conn = [[SFTPConnectionPool sharedPool] connectionWithURL:parent error:&error];
		if (conn == nil && error)
			[NSApp presentError:error];
		else {
			if (![conn createDirectory:path error:&error])
				[NSApp presentError:error];
			else
				[self rescan_files:nil];
		}
	}
}

- (IBAction)bookmarkFolder:(id)sender
{
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	NSArray *bookmarks = [defaults arrayForKey:@"bookmarks"];
	NSString *url = [[rootButton URL] absoluteString];
	if (![bookmarks containsObject:url]) {
		if (bookmarks == nil)
			bookmarks = [NSArray arrayWithObject:@"dummy"];
		[defaults setObject:[bookmarks arrayByAddingObject:url] forKey:@"bookmarks"];
	}
}

- (IBAction)gotoBookmark:(id)sender
{
	NSURL *url = [NSURL URLWithString:[sender titleOfSelectedItem]];
	[self browseURL:url];
	[environment setBaseURL:url];
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
	__block BOOL fail = NO;

	NSIndexSet *set = [self clickedIndexes];

	if ([menuItem action] == @selector(openInTab:) ||
	    [menuItem action] == @selector(openInCurrentView:) ||
	    [menuItem action] == @selector(openInSplit:) ||
	    [menuItem action] == @selector(openInVerticalSplit:)) {
		/*
		 * Selected files must be files, not directories.
		 */
		[set enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
			ProjectFile *item = [explorer itemAtRow:idx];
			if (item == nil || [self outlineView:explorer isItemExpandable:item]) {
				*stop = YES;
				fail = YES;
			}
		}];
		if (fail)
			return NO;
	}

	/*
	 * Some items only operate on a single entry.
	 */
	if ([set count] > 1 &&
	   ([menuItem action] == @selector(openInCurrentView:) ||
	    [menuItem action] == @selector(renameFile:) ||
	    [menuItem action] == @selector(openInSplit:) ||		/* XXX: Splitting multiple documents is disabled for now, buggy */
	    [menuItem action] == @selector(openInVerticalSplit:)))
		return NO;

	/*
	 * Some items need at least one selected entry.
	 */
	if ([set count] == 0 && [explorer clickedRow] == -1 &&
	   ([menuItem action] == @selector(openInTab:) ||
	    [menuItem action] == @selector(openInCurrentView:) ||
	    [menuItem action] == @selector(openInSplit:) ||
	    [menuItem action] == @selector(openInVerticalSplit:) ||
	    [menuItem action] == @selector(renameFile:) ||
	    [menuItem action] == @selector(removeFiles:) ||
	    [menuItem action] == @selector(revealInFinder:) ||
	    [menuItem action] == @selector(openWithFinder:)))
		return NO;

	/*
	 * Finder operations only implemented for file:// urls.
	 */
	if (![[[explorer itemAtRow:[set firstIndex]] url] isFileURL] &&
	    ([menuItem action] == @selector(revealInFinder:) ||
	     [menuItem action] == @selector(openWithFinder:)))
		return NO;

	if ([menuItem action] == @selector(newDocument:))
		return NO;

	return YES;
}

/* FIXME: do this when filter field loses focus */
- (void)resetExplorerView
{
	[filterField setStringValue:@""];
	[self filterFiles:self];
}

- (void)explorerClick:(id)sender
{
	NSIndexSet *set = [explorer selectedRowIndexes];

	if ([set count] > 1)
		return;

	ProjectFile *item = [explorer itemAtRow:[set firstIndex]];
	if (item == nil)
		return;

	// XXX: open in splits instead if alt key pressed?
	[self openInTab:sender];
}

- (void)explorerDoubleClick:(id)sender
{
	NSIndexSet *set = [explorer selectedRowIndexes];
	if ([set count] > 1)
		return;
	ProjectFile *item = [explorer itemAtRow:[set firstIndex]];
	if (item && [self outlineView:explorer isItemExpandable:item]) {
		[self browseURL:[item url]];
		[self cancelExplorer];
	} else
		[self explorerClick:sender];
}

- (IBAction)searchFiles:(id)sender
{
	[self openExplorerTemporarily:YES];
	[window makeFirstResponder:filterField];
}

- (BOOL)explorerIsOpen
{
	return ![splitView isSubviewCollapsed:explorerView];
}

- (void)openExplorerTemporarily:(BOOL)temporarily
{
	if (![self explorerIsOpen]) {
		if (temporarily)
			closeExplorerAfterUse = YES;
		[splitView setPosition:200.0 ofDividerAtIndex:0];
	}
}

- (void)closeExplorer
{
	[splitView setPosition:0.0 ofDividerAtIndex:0];
}

- (IBAction)toggleExplorer:(id)sender
{
	if ([self explorerIsOpen])
		[self closeExplorer];
	else
		[self openExplorerTemporarily:NO];
}

- (IBAction)focusExplorer:(id)sender
{
	[self openExplorerTemporarily:YES];
	[window makeFirstResponder:explorer];

	[explorer selectRowIndexes:[NSIndexSet indexSetWithIndex:explorer.lastSelectedRow]
	      byExtendingSelection:NO];
	[explorer scrollRowToVisible:explorer.lastSelectedRow];
}

- (void)cancelExplorer
{
	if (closeExplorerAfterUse) {
		[self closeExplorer];
		closeExplorerAfterUse = NO;
	}
	[self resetExplorerView];
	[delegate focusEditor];
}

- (void)markItem:(ProjectFile *)item
   withFileMatch:(ViRegexpMatch *)fileMatch
       pathMatch:(ViRegexpMatch *)pathMatch
{
	NSString *relpath = [item pathRelativeToURL:[rootButton URL]];
	NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:relpath];

	NSUInteger i;
	for (i = 1; i <= [pathMatch count]; i++) {
		NSRange range = [pathMatch rangeOfSubstringAtIndex:i];
		if (range.length > 0)
			[s addAttribute:NSFontAttributeName
			          value:[NSFont boldSystemFontOfSize:11.0]
			          range:range];
	}

	NSUInteger offset = [relpath length] - [[item name] length];

	for (i = 1; i <= [fileMatch count]; i++) {
		NSRange range = [fileMatch rangeOfSubstringAtIndex:i];
		if (range.length > 0) {
			range.location += offset;
			[s addAttribute:NSFontAttributeName
			          value:[NSFont boldSystemFontOfSize:11.0]
			          range:range];
		}
	}

	[s addAttribute:NSParagraphStyleAttributeName
	          value:matchParagraphStyle
	          range:NSMakeRange(0, [s length])];
	[item setMarkedString:s];
}

- (void)markItem:(ProjectFile *)item withPrefix:(NSUInteger)length
{
	NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:[item name]];
	[s addAttribute:NSFontAttributeName
	          value:[NSFont boldSystemFontOfSize:11.0]
	          range:NSMakeRange(0, length)];
	[s addAttribute:NSParagraphStyleAttributeName
	          value:matchParagraphStyle
	          range:NSMakeRange(0, [s length])];
	[item setMarkedString:s];
}

/* From fuzzy_file_finder.rb by Jamis Buck (public domain).
 *
 * Determine the score of this match.
 * 1. fewer "inside runs" (runs corresponding to the original pattern)
 *    is better.
 * 2. better coverage of the actual path name is better
 */
- (double)scoreForMatch:(ViRegexpMatch *)match inSegments:(NSUInteger)nsegments
{
	NSUInteger totalLength = [match rangeOfMatchedString].length;

	NSUInteger insideLength = 0;
	NSUInteger i;
	for (i = 1; i < [match count]; i++)
		insideLength += [match rangeOfSubstringAtIndex:i].length;

	double run_ratio = ([match count] == 1) ? 1 : (double)nsegments / (double)([match count] - 1);
	double char_ratio = (insideLength == 0 || totalLength == 0) ? 1 : (double)insideLength / (double)totalLength;

	return run_ratio * char_ratio;
}

static NSInteger
sort_by_score(id a, id b, void *context)
{
	double a_score = [(ProjectFile *)a score];
	double b_score = [(ProjectFile *)b score];

	if (a_score < b_score)
		return NSOrderedDescending;
	else if (a_score > b_score)
		return NSOrderedAscending;
	return NSOrderedSame;
}

- (void)expandNextItem:(id)dummy
{
	if (!isFiltering || [itemsToFilter count] == 0)
		return;

	ProjectFile *item = [itemsToFilter objectAtIndex:0];
	[itemsToFilter removeObjectAtIndex:0];
	DEBUG(@"expanding children of next item %@", item);
	[self expandItems:[item children] recursionLimit:3];

	if ([itemsToFilter count] > 0)
		[self performSelector:@selector(expandNextItem:) withObject:nil afterDelay:0.05];
	[filteredItems sortUsingFunction:sort_by_score context:nil];
	[explorer reloadData];
}

- (void)expandItems:(NSArray *)items recursionLimit:(int)recursionLimit
{
	NSString *reldir = nil;
	ViRegexpMatch *pathMatch;
	double pathScore, fileScore;

	for (ProjectFile *item in items) {
		DEBUG(@"got item %@", [item url]);
		if ([self outlineView:explorer isItemExpandable:item]) {
			if (recursionLimit > 0 && [item hasCachedChildren])
				[self expandItems:[item children] recursionLimit:recursionLimit - 1];
			else
				/* schedule in runloop */
				[itemsToFilter addObject:item];
		} else {
			if (reldir == nil) {
				/* Only calculate the path score once for a directory. */
				reldir = [item pathRelativeToURL:[rootButton URL]];
				if ((pathMatch = [pathRx matchInString:reldir]) != nil)
					pathScore = [self scoreForMatch:pathMatch
							     inSegments:[reldir occurrencesOfCharacter:'/'] + 1];
			}

			if (pathMatch != nil) {
				ViRegexpMatch *fileMatch;
				if ((fileMatch = [fileRx matchInString:[item name]]) != nil) {
					fileScore = [self scoreForMatch:fileMatch inSegments:1];
					[self markItem:item withFileMatch:fileMatch pathMatch:pathMatch];
					[item setScore:pathScore * fileScore];
					[filteredItems addObject:item];
				}
			}
		}
	}
}

- (void)appendFilter:(NSString *)filter toPattern:(NSMutableString *)pattern
{
	NSUInteger i;
	for (i = 0; i < [filter length]; i++) {
		unichar c = [filter characterAtIndex:i];
		if (i != 0)
			[pattern appendString:@"[^/]*?"];
		[pattern appendFormat:@"(%s%C)", c == '.' ? "\\" : "", c];
	}
}

- (IBAction)filterFiles:(id)sender
{
	NSString *filter = [filterField stringValue];

	if ([filter length] == 0) {
		isFiltered = NO;
		isFiltering = NO;
		filteredItems = [NSMutableArray arrayWithArray:rootItems];
		[explorer reloadData];
		[explorer selectRowIndexes:[NSIndexSet indexSet]
		      byExtendingSelection:NO];
	} else {
		NSArray *components = [filter componentsSeparatedByString:@"/"];

		NSMutableString *pathPattern = [NSMutableString string];
		[pathPattern appendString:@"^.*?"];
		NSUInteger i;
		for (i = 0; i < [components count] - 1; i++) {
			if (i != 0)
				[pathPattern appendString:@".*?/.*?"];
			[self appendFilter:[components objectAtIndex:i]
				 toPattern:pathPattern];
		}
		[pathPattern appendString:@".*?$"];
		pathRx = [[ViRegexp alloc] initWithString:pathPattern
						  options:ONIG_OPTION_IGNORECASE];

		NSMutableString *filePattern = [NSMutableString string];
		[filePattern appendString:@"^.*?"];
		[self appendFilter:[components lastObject] toPattern:filePattern];
		[filePattern appendString:@".*$"];
		fileRx = [[ViRegexp alloc] initWithString:filePattern
						  options:ONIG_OPTION_IGNORECASE];

		filteredItems = [NSMutableArray array];
		itemsToFilter = [NSMutableArray array];
		isFiltered = YES;
		isFiltering = YES;

		[self expandItems:rootItems recursionLimit:3];
		[filteredItems sortUsingFunction:sort_by_score context:nil];
		[explorer reloadData];
		[explorer selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
		      byExtendingSelection:NO];
		if ([itemsToFilter count] > 0)
			[self performSelector:@selector(expandNextItem:)
				   withObject:nil
				   afterDelay:0.05];
        }
}

#pragma mark -

- (BOOL)control:(NSControl *)sender
       textView:(NSTextView *)textView
doCommandBySelector:(SEL)aSelector
{
	if (aSelector == @selector(insertNewline:)) { // enter
		NSIndexSet *set = [explorer selectedRowIndexes];
		if ([set count] == 0)
			[self cancelExplorer];
		else
			[self explorerClick:sender];
		return YES;
	} else if (aSelector == @selector(moveUp:)) { // up arrow
		NSInteger row = [explorer selectedRow];
		if (row > 0)
			[explorer selectRowIndexes:[NSIndexSet indexSetWithIndex:row - 1]
			      byExtendingSelection:NO];
		return YES;
	} else if (aSelector == @selector(moveDown:)) { // down arrow
		NSInteger row = [explorer selectedRow];
		if (row + 1 < [explorer numberOfRows])
			[explorer selectRowIndexes:[NSIndexSet indexSetWithIndex:row + 1]
			      byExtendingSelection:NO];
		return YES;
	} else if (aSelector == @selector(moveRight:)) { // right arrow
		NSInteger row = [explorer selectedRow];
		id item = [explorer itemAtRow:row];
		if (item && [self outlineView:explorer isItemExpandable:item])
			[explorer expandItem:item];
		return YES;
	} else if (aSelector == @selector(moveLeft:)) { // left arrow
		NSInteger row = [explorer selectedRow];
		id item = [explorer itemAtRow:row];
		if (item == nil)
			return YES;
		if ([self outlineView:explorer isItemExpandable:item] &&
		    [explorer isItemExpanded:item])
			[explorer collapseItem:item];
		else {
			id parent = [explorer parentForItem:item];
			if (parent) {
				row = [explorer rowForItem:parent];
				[explorer selectRowIndexes:[NSIndexSet indexSetWithIndex:row]
				      byExtendingSelection:NO];
				[explorer scrollRowToVisible:row];
			}
		}
		return YES;
	} else if (aSelector == @selector(cancelOperation:)) { // escape
		isFiltering = NO;
		if (isFiltered) {
			[window makeFirstResponder:explorer];
			/* make sure something is selected */
			if ([explorer selectedRow] == -1)
				[explorer selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
				      byExtendingSelection:NO];
		} else
			[self cancelExplorer];
		return YES;
	}

	return NO;
}

#pragma mark -
#pragma mark Explorer Command Parser

- (BOOL)show_menu:(ViCommand *)command
{
	[self actionMenu:explorer];
	return YES;
}

- (BOOL)find:(ViCommand *)command
{
	[window makeFirstResponder:filterField];
	return YES;
}

- (BOOL)cancel_or_reset:(ViCommand *)command
{
	if (isFiltered)
		[self resetExplorerView];
	else
		[self cancelExplorer];
	return YES;
}

- (BOOL)cancel:(ViCommand *)command
{
	[self cancelExplorer];
	return YES;
}

- (BOOL)switch_open:(ViCommand *)command
{
	[self openInCurrentView:nil];
	return YES;
}

- (BOOL)split_open:(ViCommand *)command
{
	[self openInSplit:nil];
	return YES;
}

- (BOOL)vsplit_open:(ViCommand *)command
{
	[self openInVerticalSplit:nil];
	return YES;
}

- (BOOL)tab_open:(ViCommand *)command
{
	[self openInTab:nil];
	return YES;
}

- (BOOL)open:(ViCommand *)command
{
	[self explorerDoubleClick:nil];
	return YES;
}

- (BOOL)rescan_files:(ViCommand *)command
{
	NSInteger row = [explorer selectedRow];

	[self rescan:nil];

	if (row > [explorer numberOfRows])
		row = [explorer numberOfRows] - 1;

	if (row < 0)
		[explorer move_home:command];
	else {
		[explorer selectRowIndexes:[NSIndexSet indexSetWithIndex:row]
		      byExtendingSelection:NO];
		[explorer scrollRowToVisible:row];
		explorer.lastSelectedRow = row;
	}

	return YES;
}

- (BOOL)new_folder:(ViCommand *)command
{
	[self newFolder:nil];
	return YES;
}

- (BOOL)remove_files:(ViCommand *)command
{
	[self removeFiles:nil];
	return YES;
}

- (BOOL)keyManager:(ViKeyManager *)keyManager
   evaluateCommand:(ViCommand *)command
{
	DEBUG(@"command is %@", command);
	id target;
	if ([explorer respondsToSelector:command.action])
		target = explorer;
	else if ([self respondsToSelector:command.action])
		target = self;
	else {
		[windowController message:@"Command not implemented."];
		return NO;
	}

	return (BOOL)[target performSelector:command.action withObject:command];
}

#pragma mark -
#pragma mark Explorer Outline View Data Source

- (id)outlineView:(NSOutlineView *)outlineView
            child:(NSInteger)anIndex
           ofItem:(id)item
{
	if (item == nil)
		return [filteredItems objectAtIndex:anIndex];
	return [[(ProjectFile *)item children] objectAtIndex:anIndex];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView
   isItemExpandable:(id)item
{
	return [(ProjectFile *)item isDirectory];
}

- (NSInteger)outlineView:(NSOutlineView *)outlineView
  numberOfChildrenOfItem:(id)item
{
	if (item == nil)
		return [filteredItems count];

	return [[(ProjectFile *)item children] count];
}

- (id)outlineView:(NSOutlineView *)outlineView
objectValueForTableColumn:(NSTableColumn *)tableColumn
           byItem:(id)item
{
	if (isFiltered)
		return [item markedString];
        else
		return [(ProjectFile *)item name];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView
        isGroupItem:(id)item
{
	return NO;
}

- (CGFloat)outlineView:(NSOutlineView *)outlineView
     heightOfRowByItem:(id)item
{
	return 20;
}

- (NSCell *)outlineView:(NSOutlineView *)outlineView
 dataCellForTableColumn:(NSTableColumn *)tableColumn
                   item:(id)item
{
	NSCell *cell = [tableColumn dataCellForRow:[explorer rowForItem:item]];
	if (cell) {
		NSURL *url = [item url];
		NSImage *img;
		if ([url isFileURL])
			img = [[NSWorkspace sharedWorkspace] iconForFile:[url path]];
		else {
			if ([self outlineView:outlineView isItemExpandable:item])
				img = [[NSWorkspace sharedWorkspace] iconForFileType:NSFileTypeForHFSTypeCode('fldr')];
			else
				img = [[NSWorkspace sharedWorkspace] iconForFileType:[[url path] pathExtension]];
		}

		[cell setFont:[NSFont systemFontOfSize:11.0]];
		[img setSize:NSMakeSize(16, 16)];
		[cell setImage:img];
	}

	return cell;
}

@end