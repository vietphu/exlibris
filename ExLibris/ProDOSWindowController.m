//
//  ProDOSImageController.m
//  Disk II
//
//  Created by David Schweinsberg on 1/01/08.
//  Copyright 2008 David Schweinsberg. All rights reserved.
//

#import "ProDOSWindowController.h"
#import "ProDOSImage.h"
#import "PDVolume.h"
#import "PDDirectory.h"
#import "PDFileEntry.h"
#import "PDDirectoryHeader.h"
#import "PDFileType.h"
#import "ResourceManager.h"
#import "FileBrowseController.h"
#import "GraphicsBrowseController.h"
#import "ProDOSInfoWindowController.h"
#import "PDFileNameFormatter.h"
#import "PDFileTypeFormatter.h"
#import "PDAccessFormatter.h"
#import "SYHexFormatter.h"
#import "DiskII.h"
#import "ExLibrisErrors.h"

@interface ProDOSWindowController (Private)

- (PDEntry *)selectedEntry;

- (void)deleteSubdirectory:(PDFileEntry *)fileEntry;

@end

@implementation ProDOSWindowController

- (id)init
{
    self = [super initWithWindowNibName:@"ProDOSWindow"];
    if (self)
    {
        // When the user closes the volume window, we want all other windows
        // attached to the volume (file browsers, etc) to close also
        [self setShouldCloseDocument:YES];

        // Other controllers accessing this document
        windowControllers = [[NSMutableDictionary alloc] init];
        
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self
               selector:@selector(handleShowAllDirectoryEntriesChange:)
                   name:ShowAllDirectoryEntriesChanged
                 object:nil];
    }
    return self;
}

- (void)dealloc
{
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc removeObserver:self];

    [windowControllers release];
    [super dealloc];
}

- (NSString *)windowTitleForDocumentDisplayName:(NSString *)displayName
{
    ProDOSImage *image = self.document;
    PDVolume *volume = (PDVolume *)image.volume;
    NSMutableString *ms = [[[NSMutableString alloc] init] autorelease];
    [ms appendFormat:@"%@ (%@)", volume.name, displayName];
    return ms;
}

- (void)windowDidLoad
{
    [super windowDidLoad];

    // Attach some custom formatters to the outline view
    NSTableColumn *column = [catalogOutlineView.tableColumns objectAtIndex:0];
    [column.dataCell setFormatter:[[[PDFileNameFormatter alloc] init] autorelease]];
    column = [catalogOutlineView.tableColumns objectAtIndex:1];
    [column.dataCell setFormatter:[[[PDFileTypeFormatter alloc] init] autorelease]];
    column = [catalogOutlineView.tableColumns objectAtIndex:6];
    [column.dataCell setFormatter:[[[SYHexFormatter alloc] init] autorelease]];
    column = [catalogOutlineView.tableColumns objectAtIndex:7];
    [column.dataCell setFormatter:[[[PDAccessFormatter alloc] init] autorelease]];

    // Arrange the ability to drag files around
    [catalogOutlineView registerForDraggedTypes:
        [NSArray arrayWithObject:NSFilesPromisePboardType]];
    [catalogOutlineView setDraggingSourceOperationMask:NSDragOperationCopy
                                              forLocal:NO];
}

- (void)setDocumentEdited:(BOOL)flag
{
    NSLog(@"DiskImageController told of edit");

    [super setDocumentEdited:flag];
}

- (NSString *)outlineView:(NSOutlineView *)ov
           toolTipForCell:(NSCell *)cell
                     rect:(NSRectPointer)rect
              tableColumn:(NSTableColumn *)tableColumn
                     item:(id)item
            mouseLocation:(NSPoint)mouseLocation
{
    PDEntry *entry = item;
    if ([tableColumn.identifier isEqualToString:@"fileName"])
    {
        unsigned int storageType = entry.storageType;
        if (storageType == 15)
            return @"Volume Directory Header";
        else if (storageType == 14)
            return @"Subdirectory Header";
        else
            return @"File Entry";
    }
    else if ([entry isKindOfClass:[PDFileEntry class]])
    {
        PDFileEntry *fileEntry = (PDFileEntry *)entry;
        if ([tableColumn.identifier isEqualToString:@"fileType"])
        {
            // Find a tool tip for the file type
            NSString *toolTip = fileEntry.fileType.description;
            if (!toolTip)
                toolTip = @"Unknown file type";
            return toolTip;
        }
    }
    return nil;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView
         writeItems:(NSArray *)items
       toPasteboard:(NSPasteboard *)pboard
{
    // What file type can we specify here?
    NSArray *fileTypeList = [NSArray arrayWithObject:@""];
    [pboard declareTypes:[NSArray arrayWithObject:NSFilesPromisePboardType]
                   owner:self];
    [pboard setPropertyList:fileTypeList
                    forType:NSFilesPromisePboardType];
    
    NSLog(@"Dragging");
    
    return YES;
}

- (NSArray *)outlineView:(NSOutlineView *)outlineView
namesOfPromisedFilesDroppedAtDestination:(NSURL *)dropDestination
         forDraggedItems:(NSArray *)items
{
    NSLog(@"Drag file promise accepted to: %@", dropDestination);

    ProDOSImage *image = self.document;
    PDVolume *volume = (PDVolume *)image.volume;
    NSMutableArray *fileNames = [NSMutableArray array];
    for (PDEntry *entry in items)
    {
        if ([entry isKindOfClass:[PDFileEntry class]])
        {
            PDFileEntry *fileEntry = (PDFileEntry *)entry;
            NSURL *url = [NSURL URLWithString:fileEntry.fileName
                                relativeToURL:dropDestination];
            NSData *data = [volume dataForEntry:fileEntry includeMetadata:NO];
            [data writeToURL:url atomically:NO];
            
            // Store the ProDOS metadata in the resource fork
            ResourceManager *rm = [[ResourceManager alloc] initWithURL:url];
            
            [rm release];
        
            [fileNames addObject:fileEntry.fileName];
            
            NSLog(@"Written: %@", fileEntry.fileName);
        }
    }
    return fileNames;
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
    NSLog(@"Validating %@", NSStringFromSelector(menuItem.action));

    if ((menuItem.action == @selector(viewFile:))
        || (menuItem.action == @selector(copy:))
        || (menuItem.action == @selector(delete:))
        || (menuItem.action == @selector(getInfo:)))
    {
        NSArray *selectedObjects = catalogTreeController.selectedObjects;
        if (selectedObjects.count > 0)
            return YES;
    }
    else if (menuItem.action == @selector(openGraphics:))
    {
        NSArray *selectedObjects = catalogTreeController.selectedObjects;
        if (selectedObjects.count > 0)
        {
            PDFileEntry *fileEntry = [selectedObjects objectAtIndex:0];
            if (fileEntry.fileType.typeId == BINARY_FILE_TYPE_ID
                && (fileEntry.auxType == 0x2000 || fileEntry.auxType == 0x4000))
                return YES;
        }
    }
    else if (menuItem.action == @selector(paste:))
    {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        
        // Is there data of interest on the pasteboard?
        // (for the moment we're just going to handle ProDOS files)
        NSString *type = [pb availableTypeFromArray:[NSArray arrayWithObject:ProDOSFilePboardType]];
        if ([type isEqualToString:ProDOSFilePboardType])
            return YES;
    }
    else if (menuItem.action == @selector(createSubdirectory:))
        return YES;

    return NO;
}

- (IBAction)copy:(id)sender
{
    NSPasteboard *pb = [NSPasteboard generalPasteboard];

    [pb declareTypes:[NSArray arrayWithObject:ProDOSFilePboardType]
               owner:self];

    PDEntry *entry = self.selectedEntry;
    if (entry)
    {
        ProDOSImage *image = self.document;
        PDVolume *volume = (PDVolume *)image.volume;
        NSData *data = [volume dataForEntry:entry includeMetadata:YES];
        [pb setData:data forType:ProDOSFilePboardType];
    
        NSLog(@"Copy ProDOS file to pasteboard");
    }
}

- (IBAction)paste:(id)sender
{
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    
    // Is there data of interest on the pasteboard?
    // (for the moment we're just going to handle ProDOS files)
    NSString *type = [pb availableTypeFromArray:[NSArray arrayWithObject:ProDOSFilePboardType]];
    if ([type isEqualToString:ProDOSFilePboardType])
    {
        NSLog(@"Pasting ProDOS file from pasteboard");
        
        NSData *data = [pb dataForType:ProDOSFilePboardType];
        
        // Split pasteboard into file data and metadata
        unsigned char metaLen = ((unsigned char *)data.bytes)[0];
        NSRange metaRange = NSMakeRange(1, metaLen);
        NSRange fileRange = NSMakeRange(metaLen + 1, data.length - (metaLen + 1));
        NSData *metadata = [data subdataWithRange:metaRange];
        NSData *fileData = [data subdataWithRange:fileRange];

        // Where are we pasting this file?
        PDDirectory *directory = nil;
        PDEntry *entry = self.selectedEntry;
        if (entry)
        {
            // If the entry is a directory, paste into that directory, otherwise
            // paste into entry's parent directory
            if ([entry isKindOfClass:[PDFileEntry class]])
            {
                PDFileEntry *fileEntry = (PDFileEntry *)entry;
                if (fileEntry.directory)
                    directory = fileEntry.directory;
            }
            
            if (!directory)
                directory = entry.parentDirectory;
        }
        
        ProDOSImage *image = self.document;
        PDVolume *volume = (PDVolume *)image.volume;

        if (!directory)
        {
            // When no destination is selected, put it in the volume directory
            directory = volume.directory;
        }

        if (directory)
        {
            // PDFileEntry needs to be backed by mutable data long enough for it
            // to be copied by the 'createFileWithEntry' method
            NSMutableData *mutableMetadata = [NSMutableData dataWithData:metadata];
            PDFileEntry *fileEntry = [[PDFileEntry alloc] initWithVolume:volume
                                                         parentDirectory:directory
                                                             parentEntry:nil
                                                                   bytes:mutableMetadata.mutableBytes
                                                                  length:mutableMetadata.length];
            
            // Do the business
            [directory createFileWithEntry:fileEntry data:fileData];

            [fileEntry release];
        }
    }
}

- (IBAction)delete:(id)sender
{
    PDEntry *entry = self.selectedEntry;
    if (!entry)
        return;

    // Sort out the undo manager
//    NSUndoManager *undo = self.undoManager;
//    [[undo prepareWithInvocationTarget:self] insertEntry:entry];
//    if (![undo isUndoing])
//    {
//        NSString *actionName = [NSString stringWithFormat:@"Delete %@",
//                                entry.fileName];
//        [undo setActionName:actionName];
//    }
    
    // Do the actual deletion
    if ([entry isKindOfClass:[PDFileEntry class]])
    {
        PDFileEntry *fileEntry = (PDFileEntry *)entry;
        if (fileEntry.directory)
            [self deleteSubdirectory:fileEntry];
    }
}

- (void)deleteSubdirectory:(PDFileEntry *)fileEntry
{
    [fileEntry.directory deleteFileEntry:fileEntry];
}

- (IBAction)openGraphics:(id)sender
{
    PDEntry *entry = self.selectedEntry;
    if (entry)
    {
        // Is window already being shown?
        NSString *key = [NSString stringWithFormat:@"%@ Graphics", entry.description];
        NSWindowController *windowController = [windowControllers objectForKey:key];
        if (!windowController)
        {
            ProDOSImage *di = self.document;
            PDVolume *volume = (PDVolume *)di.volume;
            NSData *data = [volume dataForEntry:entry includeMetadata:NO];
            windowController = [[GraphicsBrowseController alloc] initWithData:data
                                                                         name:entry.fileName
                                                                    hasHeader:NO];
            [windowControllers setObject:windowController forKey:key];
            [self.document addWindowController:windowController];
        }
        [windowController showWindow:self];
    }
}

- (IBAction)getInfo:(id)sender
{
    PDEntry *entry = self.selectedEntry;
    if (entry)
    {
        // Is info already being shown?
        NSString *key = [NSString stringWithFormat:@"%@ Info", entry.description];
        NSWindowController *windowController = [windowControllers objectForKey:key];
        if (!windowController)
        {
            windowController = [[ProDOSInfoWindowController alloc] initWithEntry:entry];
            [windowControllers setObject:windowController forKey:key];
            [self.document addWindowController:windowController];
        }
        [windowController showWindow:self];
    }
}

- (IBAction)createSubdirectory:(id)sender
{
    // Where are we creating this subdirectory?
    PDDirectory *directory = nil;
    PDEntry *entry = self.selectedEntry;
    if (entry)
    {
        // If the entry is a directory, create in that directory, otherwise
        // create subdirectory in entry's parent directory
        if ([entry isKindOfClass:[PDFileEntry class]])
        {
            PDFileEntry *fileEntry = (PDFileEntry *)entry;
            if (fileEntry.directory)
                directory = fileEntry.directory;
        }
        
        if (!directory)
            directory = entry.parentDirectory;
    }
    
    ProDOSImage *image = self.document;
    PDVolume *volume = (PDVolume *)image.volume;
    
    if (!directory)
    {
        // When no destination is selected, put it in the volume directory
        directory = volume.directory;
    }
    
    if (directory)
    {
        NSString *name = [directory uniqueNameFromString:@"NEW.DIR"];
        NSError *error;
        if ([directory createDirectoryWithName:name error:&error] == NO)
        {
            NSAlert *alert = [NSAlert alertWithError:error];
            [alert beginSheetModalForWindow:self.window
                              modalDelegate:self
                             didEndSelector:@selector(alertDidEnd:returnCode:contextInfo:)
                                contextInfo:nil];
        }
    }
}

- (IBAction)viewFile:(id)sender
{
    PDEntry *entry = self.selectedEntry;
    if (entry)
        [self showFileBrowse:[NSArray arrayWithObject:entry]];
}

- (IBAction)enterSearchQuery:(id)sender
{
    // If there is something in the search field, switch to the tab view showing
    // showing search results.  Otherwise show the main tree view.
    if (searchField.stringValue.length > 0)
    {
        [tabView selectTabViewItemAtIndex:1];
    }
    else
        [tabView selectTabViewItemAtIndex:0];
}

- (void)showFileBrowse:(NSArray *)entries
{
    PDEntry *entry = [entries objectAtIndex:0];
    if (entry)
    {
        // Is this file already being browsed?  If so, it will appear in our
        // list of fileBrowseControllers.
        NSString *key = [NSString stringWithFormat:@"%@ File", entry.description];
        NSWindowController *windowController = [windowControllers objectForKey:key];
        if (!windowController)
        {
            // NOTE: The following alert code does nothing at this stage, since the
            // FileBrowseController will always succeed.  If the storage type is
            // unhandled, then there will be a message reporting as such in the
            // file browser.
            ProDOSImage *di = self.document;
            PDVolume *volume = (PDVolume *)di.volume;
            NSData *data = [volume dataForEntry:entry includeMetadata:NO];
            if (data)
            {
                NSUInteger typeId = 0;
                NSUInteger startAddress = 0;
                if ([entry isKindOfClass:[PDFileEntry class]])
                {
                    PDFileEntry *fileEntry = (PDFileEntry *)entry;
                    typeId = fileEntry.fileType.typeId;
                    if (typeId == BINARY_FILE_TYPE_ID || typeId == SYSTEM_FILE_TYPE_ID)
                        startAddress = fileEntry.auxType;
                }
                else if ([entry isKindOfClass:[PDDirectoryHeader class]])
                {
                    typeId = DIRECTORY_FILE_TYPE_ID;
                }
                windowController = [[FileBrowseController alloc] initWithData:data
                                                                 startAddress:startAddress
                                                                         name:entry.fileName
                                                                       typeId:typeId
                                                                    hasHeader:NO];
            }
            
            if (windowController)
            {
                [windowControllers setObject:windowController forKey:key];
                [self.document addWindowController:windowController];
            }
            else
                [NSAlert alertWithMessageText:@"Unhandled storage type"
                                defaultButton:nil
                              alternateButton:nil
                                  otherButton:nil
                    informativeTextWithFormat:nil];
        }
        [windowController showWindow:self];
        
        NSLog(@"Browsing: %@", entry.description);
    }
}

- (void)handleShowAllDirectoryEntriesChange:(NSNotification *)note
{
    ProDOSImage *di = self.document;
    PDVolume *volume = (PDVolume *)di.volume;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    volume.directory.allEntriesVisible = [defaults boolForKey:ShowAllDirectoryEntriesKey];
}

- (PDEntry *)selectedEntry
{
    NSArray *selectedObjects = catalogTreeController.selectedObjects;
    if (selectedObjects.count > 0)
        return [selectedObjects objectAtIndex:0];
    return nil;
}

- (void)alertDidEnd:(NSAlert *)alert
         returnCode:(int)returnCode
        contextInfo:(void *)contextInfo
{
}

@end
