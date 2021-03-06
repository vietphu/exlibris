//
//  Volume.h
//  Disk II
//
//  Created by David Schweinsberg on 25/10/08.
//  Copyright 2008 David Schweinsberg. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@class BlockStorage;

@interface Volume : NSObject
{
    NSObject *container;
    BlockStorage *blockStorage;
}

@property(retain, readonly) BlockStorage *blockStorage;

@property(copy, readonly) NSString *name;

- (id)initWithContainer:(NSObject *)aContainer
           blockStorage:(BlockStorage *)aBlockStorage;

@end
