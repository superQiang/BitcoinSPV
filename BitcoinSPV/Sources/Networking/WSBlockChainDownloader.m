//
//  WSBlockChainDownloader.m
//  BitcoinSPV
//
//  Created by Davide De Rosa on 24/08/15.
//  Copyright (c) 2015 Davide De Rosa. All rights reserved.
//
//  http://github.com/keeshux
//  http://twitter.com/keeshux
//  http://davidederosa.com
//
//  This file is part of BitcoinSPV.
//
//  BitcoinSPV is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  BitcoinSPV is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with BitcoinSPV.  If not, see <http://www.gnu.org/licenses/>.
//

#import "WSBlockChainDownloader.h"
#import "WSPeerGroup+Download.h"
#import "WSBlockStore.h"
#import "WSBlockChain.h"
#import "WSBlockHeader.h"
#import "WSBlock.h"
#import "WSFilteredBlock.h"
#import "WSTransaction.h"
#import "WSStorableBlock.h"
#import "WSStorableBlock+BlockChain.h"
#import "WSWallet.h"
#import "WSHDWallet.h"
#import "WSConnectionPool.h"
#import "WSBlockLocator.h"
#import "WSParameters.h"
#import "WSHash256.h"
#import "WSLogging.h"
#import "WSMacrosCore.h"
#import "WSErrors.h"
#import "WSConfig.h"

@interface WSBlockChainDownloader ()

// configuration
@property (nonatomic, strong) id<WSParameters> parameters;
@property (nonatomic, strong) id<WSBlockStore> store;
@property (nonatomic, strong) WSBlockChain *blockChain;
@property (nonatomic, strong) id<WSSynchronizableWallet> wallet;
@property (nonatomic, assign) uint32_t fastCatchUpTimestamp;
@property (nonatomic, assign) BOOL shouldDownloadBlocks;
@property (nonatomic, strong) WSBIP37FilterParameters *bloomFilterParameters;

// state
@property (nonatomic, weak) WSPeerGroup *peerGroup;
@property (nonatomic, strong) WSPeer *downloadPeer;
@property (nonatomic, strong) WSBloomFilter *bloomFilter;
@property (nonatomic, strong) NSCountedSet *pendingBlockIds;
@property (nonatomic, strong) NSMutableOrderedSet *processingBlockIds;
@property (nonatomic, strong) WSBlockLocator *startingBlockChainLocator;
@property (nonatomic, assign) NSTimeInterval lastKeepAliveTime;

- (instancetype)initWithParameters:(id<WSParameters>)parameters;

// business
- (BOOL)needsBloomFiltering;
- (WSPeer *)bestPeerAmongPeers:(NSArray *)peers; // WSPeer
- (void)downloadBlockChain;
- (void)rebuildBloomFilter;
- (void)requestHeadersWithLocator:(WSBlockLocator *)locator;
- (void)requestBlocksWithLocator:(WSBlockLocator *)locator;
- (void)aheadRequestOnReceivedHeaders:(NSArray *)headers; // WSBlockHeader
- (void)aheadRequestOnReceivedBlockHashes:(NSArray *)hashes; // WSHash256
- (void)requestOutdatedBlocks;
- (void)trySaveBlockChainToCoreData;
- (void)detectDownloadTimeout;

// blockchain
- (BOOL)appendBlockHeaders:(NSArray *)headers error:(NSError **)error; // WSBlockHeader
- (BOOL)appendBlock:(WSBlock *)fullBlock error:(NSError **)error;
- (BOOL)appendFilteredBlock:(WSFilteredBlock *)filteredBlock withTransactions:(NSOrderedSet *)transactions error:(NSError **)error; // WSSignedTransaction

// entity handlers
- (void)handleAddedBlock:(WSStorableBlock *)block;
- (void)handleReplacedBlock:(WSStorableBlock *)block;
- (void)handleReceivedTransaction:(WSSignedTransaction *)transaction;
- (void)handleReorganizeAtBase:(WSStorableBlock *)base oldBlocks:(NSArray *)oldBlocks newBlocks:(NSArray *)newBlocks;
- (void)recoverMissedBlockTransactions:(WSStorableBlock *)block;
- (BOOL)maybeRebuildAndSendBloomFilter;

// macros
- (void)logAddedBlock:(WSStorableBlock *)block onFork:(BOOL)onFork;

@end

@implementation WSBlockChainDownloader

- (instancetype)initWithParameters:(id<WSParameters>)parameters
{
    NSParameterAssert(parameters);
    
    if ((self = [super init])) {
        self.parameters = parameters;
        self.bloomFilterRateMin = WSBlockChainDownloaderDefaultBFRateMin;
        self.bloomFilterRateDelta = WSBlockChainDownloaderDefaultBFRateDelta;
        self.bloomFilterObservedRateMax = WSBlockChainDownloaderDefaultBFObservedRateMax;
        self.bloomFilterLowPassRatio = WSBlockChainDownloaderDefaultBFLowPassRatio;
        self.bloomFilterTxsPerBlock = WSBlockChainDownloaderDefaultBFTxsPerBlock;
        self.requestTimeout = WSBlockChainDownloaderDefaultRequestTimeout;

        self.pendingBlockIds = [[NSCountedSet alloc] init];
        self.processingBlockIds = [[NSMutableOrderedSet alloc] initWithCapacity:(2 * WSMessageBlocksMaxCount)];
    }
    return self;
}

- (instancetype)initWithStore:(id<WSBlockStore>)store headersOnly:(BOOL)headersOnly
{
    return [self initWithStore:store maxSize:WSBlockChainDefaultMaxSize headersOnly:headersOnly];
}

- (instancetype)initWithStore:(id<WSBlockStore>)store fastCatchUpTimestamp:(uint32_t)fastCatchUpTimestamp
{
    return [self initWithStore:store maxSize:WSBlockChainDefaultMaxSize fastCatchUpTimestamp:fastCatchUpTimestamp];
}

- (instancetype)initWithStore:(id<WSBlockStore>)store wallet:(id<WSSynchronizableWallet>)wallet
{
    return [self initWithStore:store maxSize:WSBlockChainDefaultMaxSize wallet:wallet];
}

- (instancetype)initWithStore:(id<WSBlockStore>)store maxSize:(NSUInteger)maxSize headersOnly:(BOOL)headersOnly
{
    WSExceptionCheckIllegal(store);
    if (!headersOnly) {
        WSExceptionRaiseUnsupported(@"Full blocks download not yet implemented");
    }
    
    if ((self = [self initWithParameters:store.parameters])) {
        self.store = store;
        self.blockChain = [[WSBlockChain alloc] initWithStore:self.store maxSize:maxSize];
        self.wallet = nil;
        self.fastCatchUpTimestamp = 0;

        self.shouldDownloadBlocks = !headersOnly;
        self.bloomFilterParameters = nil;
    }
    return self;
}

- (instancetype)initWithStore:(id<WSBlockStore>)store maxSize:(NSUInteger)maxSize fastCatchUpTimestamp:(uint32_t)fastCatchUpTimestamp
{
    WSExceptionCheckIllegal(store);
    WSExceptionRaiseUnsupported(@"Full blocks download not yet implemented");

    if ((self = [self initWithParameters:store.parameters])) {
        self.store = store;
        self.blockChain = [[WSBlockChain alloc] initWithStore:self.store maxSize:maxSize];
        self.wallet = nil;
        self.fastCatchUpTimestamp = fastCatchUpTimestamp;

        self.shouldDownloadBlocks = YES;
        self.bloomFilterParameters = nil;
    }
    return self;
}

- (instancetype)initWithStore:(id<WSBlockStore>)store maxSize:(NSUInteger)maxSize wallet:(id<WSSynchronizableWallet>)wallet
{
    WSExceptionCheckIllegal(store);
    WSExceptionCheckIllegal(wallet);

    if ((self = [self initWithParameters:store.parameters])) {
        self.store = store;
        self.blockChain = [[WSBlockChain alloc] initWithStore:self.store maxSize:maxSize];
        self.wallet = wallet;
        self.fastCatchUpTimestamp = [self.wallet earliestKeyTimestamp];

        self.shouldDownloadBlocks = YES;
        self.bloomFilterParameters = [[WSBIP37FilterParameters alloc] init];
#if BSPV_WALLET_FILTER == BSPV_WALLET_FILTER_UNSPENT
        self.bloomFilterParameters.flags = WSBIP37FlagsUpdateAll;
#endif
    }
    return self;
}

- (void)setCoreDataManager:(WSCoreDataManager *)coreDataManager
{
    _coreDataManager = coreDataManager;

    [self.blockChain loadFromCoreDataManager:coreDataManager];
}

#pragma mark WSPeerGroupDownloader

- (void)startWithPeerGroup:(WSPeerGroup *)peerGroup
{
    self.peerGroup = peerGroup;
    self.downloadPeer = [self bestPeerAmongPeers:[peerGroup allConnectedPeers]];
    if (!self.downloadPeer) {
        DDLogInfo(@"Delayed download until peer selection");
        return;
    }
    DDLogInfo(@"Peer %@ is new download peer", self.downloadPeer);
    
    [self downloadBlockChain];
}

- (void)stop
{
    [self trySaveBlockChainToCoreData];
    
    if (self.downloadPeer) {
        DDLogInfo(@"Download from peer %@ is being stopped", self.downloadPeer);
        
        [self.peerGroup disconnectPeer:self.downloadPeer
                                 error:WSErrorMake(WSErrorCodePeerGroupStop, @"Download stopped")];
    }
    self.downloadPeer = nil;
    self.peerGroup = nil;
}

- (NSUInteger)lastBlockHeight
{
    if (!self.downloadPeer) {
        return NSNotFound;
    }
    return self.downloadPeer.lastBlockHeight;
}

- (NSUInteger)currentHeight
{
    return self.blockChain.currentHeight;
}

- (NSUInteger)numberOfBlocksLeft
{
    return (self.downloadPeer.lastBlockHeight - self.blockChain.currentHeight);
}

- (NSArray *)recentBlocksWithCount:(NSUInteger)count
{
    NSMutableArray *recentBlocks = [[NSMutableArray alloc] initWithCapacity:count];
    WSStorableBlock *block = self.blockChain.head;
    while (block && (recentBlocks.count < count)) {
        [recentBlocks addObject:block];
        block = [block previousBlockInChain:self.blockChain];
    }
    return recentBlocks;
}

- (BOOL)isSynced
{
    return (self.blockChain.currentHeight >= self.downloadPeer.lastBlockHeight);
}

- (void)reconnectForDownload
{
    [self.peerGroup disconnectPeer:self.downloadPeer
                             error:WSErrorMake(WSErrorCodePeerGroupDownload, @"Rehashing download peer")];
}

- (void)rescanBlockChain
{
    [self.peerGroup disconnectPeer:self.downloadPeer
                             error:WSErrorMake(WSErrorCodePeerGroupRescan, @"Preparing for rescan")];
}

- (void)saveState
{
    [self trySaveBlockChainToCoreData];
}

#pragma mark WSPeerGroupDownloadDelegate

- (void)peerGroup:(WSPeerGroup *)peerGroup peerDidConnect:(WSPeer *)peer
{
    if (!self.downloadPeer) {
        self.downloadPeer = peer;
        DDLogInfo(@"Peer %@ connected, is new download peer", self.downloadPeer);

        [self downloadBlockChain];
    }
    // new peer is way ahead
    else if (peer.lastBlockHeight > self.downloadPeer.lastBlockHeight + 10) {
        DDLogInfo(@"Peer %@ connected, is way ahead of current download peer (%u >> %u)",
                  peer, peer.lastBlockHeight, self.downloadPeer.lastBlockHeight);
        
        [self.peerGroup disconnectPeer:self.downloadPeer
                                 error:WSErrorMake(WSErrorCodePeerGroupDownload, @"Found a better download peer")];
    }
}

- (void)peerGroup:(WSPeerGroup *)peerGroup peer:(WSPeer *)peer didDisconnectWithError:(NSError *)error
{
    if (peer != self.downloadPeer) {
        return;
    }

    DDLogDebug(@"Peer %@ disconnected, was download peer", peer);

    switch (error.code) {
        case WSErrorCodePeerGroupDownload: {
            break;
        }
        case WSErrorCodePeerGroupRescan: {
            DDLogDebug(@"Rescan, preparing to truncate blockchain and wallet (if any)");

            [self.store truncate];
            [self.wallet removeAllTransactions];

            const NSUInteger maxSize = self.blockChain.maxSize;
            self.blockChain = [[WSBlockChain alloc] initWithStore:self.store maxSize:maxSize];
            NSAssert(self.blockChain.currentHeight == 0, @"Expected genesis blockchain");

            DDLogDebug(@"Rescan, truncate complete");
            [self.peerGroup.notifier notifyRescan];
            break;
        }
    }
    
    self.downloadPeer = [self bestPeerAmongPeers:[peerGroup allConnectedPeers]];
    if (!self.downloadPeer) {
//        if (!self.keepDownloading) {
//            [self.peerGroup.notifier notifyDownloadFailedWithError:WSErrorMake(WSErrorCodePeerGroupStop, @"Download stopped")];
//        }
//        else {
            [self.peerGroup.notifier notifyDownloadFailedWithError:WSErrorMake(WSErrorCodePeerGroupDownload, @"No more peers for download")];
//        }
        return;
    }

    [self.peerGroup.notifier notifyDownloadFailedWithError:error];

    DDLogDebug(@"Switched to next best download peer %@", self.downloadPeer);
    
    [self downloadBlockChain];
}

- (void)peerGroup:(WSPeerGroup *)peerGroup peerDidKeepAlive:(WSPeer *)peer
{
    if (peer != self.downloadPeer) {
        return;
    }
    
    self.lastKeepAliveTime = [NSDate timeIntervalSinceReferenceDate];
}

- (void)peerGroup:(WSPeerGroup *)peerGroup peer:(WSPeer *)peer didReceiveHeaders:(NSArray *)headers
{
    if (peer != self.downloadPeer) {
        return;
    }

    [self aheadRequestOnReceivedHeaders:headers];

    NSError *error;
    if (![self appendBlockHeaders:headers error:&error] && error) {
        [peerGroup reportMisbehavingPeer:self.downloadPeer error:error];
    }
}

- (void)peerGroup:(WSPeerGroup *)peerGroup peer:(WSPeer *)peer didReceiveInventories:(NSArray *)inventories
{
    if (peer != self.downloadPeer) {
        return;
    }

    NSMutableArray *requestInventories = [[NSMutableArray alloc] initWithCapacity:inventories.count];
    NSMutableArray *requestBlockHashes = [[NSMutableArray alloc] initWithCapacity:inventories.count];
    
#warning XXX: if !shouldDownloadBlocks, only download headers of new announced blocks
    
    for (WSInventory *inv in inventories) {
        if ([inv isBlockInventory]) {
            if ([self needsBloomFiltering]) {
                [requestInventories addObject:WSInventoryFilteredBlock(inv.inventoryHash)];
            }
            else {
                [requestInventories addObject:WSInventoryBlock(inv.inventoryHash)];
            }
            [requestBlockHashes addObject:inv.inventoryHash];
        }
        else {
            [requestInventories addObject:inv];
        }
    }
    NSAssert(requestBlockHashes.count <= requestInventories.count, @"Requesting more blocks than total inventories?");
    
    if (requestInventories.count > 0) {
        [self.pendingBlockIds addObjectsFromArray:requestBlockHashes];
        [self.processingBlockIds addObjectsFromArray:requestBlockHashes];
        
        [peer sendGetdataMessageWithInventories:requestInventories];
        
        if (requestBlockHashes.count > 0) {
            [self aheadRequestOnReceivedBlockHashes:requestBlockHashes];
        }
    }
}

- (void)peerGroup:(WSPeerGroup *)peerGroup peer:(WSPeer *)peer didReceiveBlock:(WSBlock *)block
{
    if (peer != self.downloadPeer) {
        return;
    }

    NSError *error;
    if (![self appendBlock:block error:&error] && error) {
        [peerGroup reportMisbehavingPeer:self.downloadPeer error:error];
    }
}

- (BOOL)peerGroup:(WSPeerGroup *)peerGroup peer:(WSPeer *)peer shouldAddTransaction:(WSSignedTransaction *)transaction toFilteredBlock:(WSFilteredBlock *)filteredBlock
{
    if (peer != self.downloadPeer) {
        return YES;
    }

    // only accept txs from most recently requested block
    WSHash256 *blockId = filteredBlock.header.blockId;
    if ([self.pendingBlockIds countForObject:blockId] > 1) {
        DDLogDebug(@"%@ Drop transaction %@ from current filtered block %@ (outdated by new pending request)",
                   self, transaction.txId, blockId);
        
        return NO;
    }
    return YES;
}

- (void)peerGroup:(WSPeerGroup *)peerGroup peer:(WSPeer *)peer didReceiveFilteredBlock:(WSFilteredBlock *)filteredBlock withTransactions:(NSOrderedSet *)transactions
{
    if (peer != self.downloadPeer) {
        return;
    }

    WSHash256 *blockId = filteredBlock.header.blockId;

    [self.pendingBlockIds removeObject:blockId];
    if ([self.pendingBlockIds containsObject:blockId]) {
        DDLogDebug(@"%@ Drop filtered block %@ (outdated by new pending request)", self, blockId);
        return;
    }
    
    [self.processingBlockIds removeObject:blockId];

    NSError *error;
    if (![self appendFilteredBlock:filteredBlock withTransactions:transactions error:&error] && error) {
        [peerGroup reportMisbehavingPeer:self.downloadPeer error:error];
    }
}

- (void)peerGroup:(WSPeerGroup *)peerGroup peer:(WSPeer *)peer didReceiveTransaction:(WSSignedTransaction *)transaction
{
    if (peer != self.downloadPeer) {
        return;
    }

    [self handleReceivedTransaction:transaction];
}

- (BOOL)peerGroup:(WSPeerGroup *)peerGroup peer:(WSPeer *)peer shouldAcceptHeader:(WSBlockHeader *)header error:(NSError *__autoreleasing *)error
{
    WSStorableBlock *expected = [self.parameters checkpointAtHeight:(uint32_t)(self.blockChain.currentHeight + 1)];
    if (!expected) {
        return YES;
    }
    if ([header.blockId isEqual:expected.header.blockId]) {
        return YES;
    }
    
    DDLogError(@"Checkpoint validation failed at %u", expected.height);
    DDLogError(@"Expected checkpoint: %@", expected);
    DDLogError(@"Found block header: %@", header);
    
    if (error) {
        *error = WSErrorMake(WSErrorCodePeerGroupRescan, @"Checkpoint validation failed at %u (%@ != %@)",
                             expected.height, header.blockId, expected.blockId);
    }
    return NO;
}

#pragma mark Business

- (BOOL)needsBloomFiltering
{
    return (self.bloomFilterParameters != nil);
}

- (WSPeer *)bestPeerAmongPeers:(NSArray *)peers
{
    WSPeer *bestPeer = nil;
    for (WSPeer *peer in peers) {

        // double check connection status
        if (peer.peerStatus != WSPeerStatusConnected) {
            continue;
        }

        // max chain height or min ping
        if (!bestPeer ||
            (peer.lastBlockHeight > bestPeer.lastBlockHeight) ||
            ((peer.lastBlockHeight == bestPeer.lastBlockHeight) && (peer.connectionTime < bestPeer.connectionTime))) {

            bestPeer = peer;
        }
    }
    return bestPeer;
}

- (void)downloadBlockChain
{
    if (self.wallet) {
        [self rebuildBloomFilter];

        DDLogDebug(@"Loading Bloom filter for download peer %@", self.downloadPeer);
        [self.downloadPeer sendFilterloadMessageWithFilter:self.bloomFilter];
    }
    else if (self.shouldDownloadBlocks) {
        DDLogDebug(@"No wallet provided, downloading full blocks");
    }
    else {
        DDLogDebug(@"No wallet provided, downloading block headers");
    }

    DDLogInfo(@"Preparing for blockchain download");

    if (self.blockChain.currentHeight >= self.downloadPeer.lastBlockHeight) {
        const NSUInteger height = self.blockChain.currentHeight;
        [self.peerGroup.notifier notifyDownloadStartedFromHeight:height toHeight:height];
        
        DDLogInfo(@"Blockchain is up to date");
        
        [self trySaveBlockChainToCoreData];
        
        [self.peerGroup.notifier notifyDownloadFinished];
        return;
    }

    WSStorableBlock *checkpoint = [self.parameters lastCheckpointBeforeTimestamp:self.fastCatchUpTimestamp];
    if (checkpoint) {
        DDLogDebug(@"%@ Last checkpoint before catch-up: %@ (%@)",
                   self, checkpoint, [NSDate dateWithTimeIntervalSince1970:checkpoint.header.timestamp]);
        
        [self.blockChain addCheckpoint:checkpoint error:NULL];
    }
    else {
        DDLogDebug(@"%@ No fast catch-up checkpoint", self);
    }
    
    const NSUInteger fromHeight = self.blockChain.currentHeight;
    const NSUInteger toHeight = self.downloadPeer.lastBlockHeight;
    [self.peerGroup.notifier notifyDownloadStartedFromHeight:fromHeight toHeight:toHeight];
    
    self.fastCatchUpTimestamp = self.fastCatchUpTimestamp;
    self.startingBlockChainLocator = [self.blockChain currentLocator];
    self.lastKeepAliveTime = [NSDate timeIntervalSinceReferenceDate];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(detectDownloadTimeout) object:nil];
        [self performSelector:@selector(detectDownloadTimeout) withObject:nil afterDelay:self.requestTimeout];
    });
    
    if (!self.shouldDownloadBlocks || (self.blockChain.currentTimestamp < self.fastCatchUpTimestamp)) {
        [self requestHeadersWithLocator:self.startingBlockChainLocator];
    }
    else {
        [self requestBlocksWithLocator:self.startingBlockChainLocator];
    }
}

- (void)rebuildBloomFilter
{
    const NSTimeInterval rebuildStartTime = [NSDate timeIntervalSinceReferenceDate];
    self.bloomFilter = [self.wallet bloomFilterWithParameters:self.bloomFilterParameters];
    const NSTimeInterval rebuildTime = [NSDate timeIntervalSinceReferenceDate] - rebuildStartTime;
    
    DDLogDebug(@"Bloom filter rebuilt in %.3fs (false positive rate: %f)",
               rebuildTime, self.bloomFilterParameters.falsePositiveRate);
}

- (void)requestHeadersWithLocator:(WSBlockLocator *)locator
{
    NSParameterAssert(locator);

    DDLogDebug(@"%@ Behind catch-up (or headers-only mode), requesting headers with locator: %@", self, locator.hashes);
    [self.downloadPeer sendGetheadersMessageWithLocator:locator hashStop:nil];
}

- (void)requestBlocksWithLocator:(WSBlockLocator *)locator
{
    NSParameterAssert(locator);

    DDLogDebug(@"%@ Beyond catch-up (or full blocks mode), requesting block hashes with locator: %@", self, locator.hashes);
    [self.downloadPeer sendGetblocksMessageWithLocator:locator hashStop:nil];
}

- (void)aheadRequestOnReceivedHeaders:(NSArray *)headers
{
    NSParameterAssert(headers.count > 0);
    
//    const NSUInteger currentHeight = self.blockChain.currentHeight;
//
//    DDLogDebug(@"%@ Still behind (%u < %u), requesting more headers ahead of time",
//               self, currentHeight, self.lastBlockHeight);
    
    WSBlockHeader *firstHeader = [headers firstObject];
    WSBlockHeader *lastHeader = [headers lastObject];
    WSBlockHeader *lastHeaderBeforeFCU = nil;
    
    // infer the header we'll stop at
    for (WSBlockHeader *header in headers) {
        if (header.timestamp >= self.fastCatchUpTimestamp) {
            break;
        }
        lastHeaderBeforeFCU = header;
    }
//    NSAssert(lastHeaderBeforeFCU, @"No headers should have been requested beyond catch-up");
    
    if (self.shouldDownloadBlocks && !lastHeaderBeforeFCU) {
        DDLogInfo(@"%@ All received headers beyond catch-up, rerequesting blocks", self);
        
        [self requestBlocksWithLocator:self.startingBlockChainLocator];
    }
    else {
        // we won't cross fast catch-up, request more headers
        if (!self.shouldDownloadBlocks || (lastHeaderBeforeFCU == lastHeader)) {
            WSBlockLocator *locator = [[WSBlockLocator alloc] initWithHashes:@[lastHeader.blockId, firstHeader.blockId]];
            [self requestHeadersWithLocator:locator];
        }
        // we will cross fast catch-up, request blocks from crossing point
        else {
            DDLogInfo(@"%@ Last header before catch-up at block %@, timestamp %u (%@)",
                      self, lastHeaderBeforeFCU.blockId, lastHeaderBeforeFCU.timestamp,
                      [NSDate dateWithTimeIntervalSince1970:lastHeaderBeforeFCU.timestamp]);
            
            WSBlockLocator *locator = [[WSBlockLocator alloc] initWithHashes:@[lastHeaderBeforeFCU.blockId, firstHeader.blockId]];
            [self requestBlocksWithLocator:locator];
        }
    }
}

- (void)aheadRequestOnReceivedBlockHashes:(NSArray *)hashes
{
    NSParameterAssert(hashes.count > 0);
    
    if (hashes.count < WSMessageBlocksMaxCount) {
        return;
    }
    
//    const NSUInteger currentHeight = self.blockChain.currentHeight;
//
//    DDLogDebug(@"%@ Still behind (%u < %u), requesting more blocks ahead of time",
//               self, currentHeight, self.lastBlockHeight);
    
    WSHash256 *firstId = [hashes firstObject];
    WSHash256 *lastId = [hashes lastObject];
    
    WSBlockLocator *locator = [[WSBlockLocator alloc] initWithHashes:@[lastId, firstId]];
    [self requestBlocksWithLocator:locator];
}

- (void)requestOutdatedBlocks
{
    //
    // since receive* and delegate methods run on the same queue,
    // a peer should never request more hashes until delegate processed
    // all blocks with last received hashes
    //
    //
    // 1. start download calling getblocks with current chain locator
    // ...
    // 2. receiveInv called with max 500 inventories (in response to 1)
    // 3. receiveInv: call getblocks with new locator
    // 4. receiveInv: call getdata with received inventories
    // 5. processingBlocksIds.count <= 500
    // ...
    // 6. receiveInv called with max 500 inventories (in response to 3)
    // 7. receiveInv: call getblocks with new locator
    // 8. receiveInv: call getdata with received inventories
    // 9. processingBlocksIds.count <= 1000
    // ...
    // 10. receiveMerkleblock + receiveTx (in response to 4)
    // 11. processingBlockIds.count <= 500
    // ...
    // 12. receiveInv called with max 500 inventories (in response to 7)
    // 13. receiveInv: call getblocks with new locator
    // 14. receiveInv: call getdata with received inventories
    // 15. processingBlockIds.count <= 1000
    // ...
    //
    //
    // that's why processingBlockIds should reach 1000 at most (2 * max)
    //
    
    //        NSAssert(self.processingBlockIds.count <= 2 * WSMessageBlocksMaxCount, @"Processing too many blocks (%u > %u)",
    //                 self.processingBlockIds.count, 2 * WSMessageBlocksMaxCount);
    
    NSArray *outdatedIds = [self.processingBlockIds array];
    
#warning XXX: outdatedIds size shouldn't overflow WSMessageMaxInventories
    
    if (outdatedIds.count > 0) {
        DDLogDebug(@"Requesting %u outdated blocks with updated Bloom filter: %@", outdatedIds.count, outdatedIds);
        [self.downloadPeer sendGetdataMessageWithHashes:outdatedIds forInventoryType:WSInventoryTypeFilteredBlock];
    }
    else {
        DDLogDebug(@"No outdated blocks to request with updated Bloom filter");
    }
}

- (void)trySaveBlockChainToCoreData
{
    if (self.coreDataManager) {
        [self.blockChain saveToCoreDataManager:self.coreDataManager];
    }
}

// main queue
- (void)detectDownloadTimeout
{
    [self.peerGroup executeBlockInGroupQueue:^{
        const NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        const NSTimeInterval elapsed = now - self.lastKeepAliveTime;
        
        if (elapsed < self.requestTimeout) {
            const NSTimeInterval delay = self.requestTimeout - elapsed;
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(detectDownloadTimeout) object:nil];
                [self performSelector:@selector(detectDownloadTimeout) withObject:nil afterDelay:delay];
            });
            return;
        }
        
        if (self.downloadPeer) {
            [self.peerGroup disconnectPeer:self.downloadPeer
                                     error:WSErrorMake(WSErrorCodePeerGroupTimeout, @"Download timed out, disconnecting")];
        }
    } synchronously:YES];
}

#pragma mark Blockchain

- (BOOL)appendBlockHeaders:(NSArray *)headers error:(NSError *__autoreleasing *)error
{
    NSParameterAssert(headers.count > 0);
    
    for (WSBlockHeader *header in headers) {
        
        // download peer should stop requesting headers when fast catch-up reached
        if (self.shouldDownloadBlocks && (header.timestamp >= self.fastCatchUpTimestamp)) {
            break;
        }

        NSError *localError;
        WSStorableBlock *addedBlock = nil;
        __weak WSBlockChainDownloader *weakSelf = self;
        
        BOOL onFork;
        NSArray *connectedOrphans;
        addedBlock = [self.blockChain addBlockWithHeader:header
                                            transactions:nil
                                                  onFork:&onFork
                                         reorganizeBlock:^(WSStorableBlock *base, NSArray *oldBlocks, NSArray *newBlocks) {
            
            [weakSelf handleReorganizeAtBase:base oldBlocks:oldBlocks newBlocks:newBlocks];
            
        } connectedOrphans:&connectedOrphans error:&localError];
        
        if (!addedBlock) {
            if (!localError) {
                DDLogDebug(@"Header not added: %@", header);
            }
            else {
                DDLogDebug(@"Error adding header (%@): %@", localError, header);
                
                if ((localError.domain == WSErrorDomain) && (localError.code == WSErrorCodeInvalidBlock)) {
                    if (error) {
                        *error = localError;
                    }
                }
            }
            DDLogDebug(@"Current head: %@", self.blockChain.head);
            
            return NO;
        }
        
        [self logAddedBlock:addedBlock onFork:onFork];

        for (WSStorableBlock *block in [connectedOrphans arrayByAddingObject:addedBlock]) {
            [self handleAddedBlock:block];
        }
    }

    return YES;
}

- (BOOL)appendBlock:(WSBlock *)fullBlock error:(NSError *__autoreleasing *)error
{
    NSParameterAssert(fullBlock);

    NSError *localError;
    WSStorableBlock *addedBlock = nil;
    WSStorableBlock *previousHead = nil;
    __weak WSBlockChainDownloader *weakSelf = self;
    
    BOOL onFork;
    NSArray *connectedOrphans;
    previousHead = self.blockChain.head;
    addedBlock = [self.blockChain addBlockWithHeader:fullBlock.header
                                        transactions:fullBlock.transactions
                                              onFork:&onFork
                                     reorganizeBlock:^(WSStorableBlock *base, NSArray *oldBlocks, NSArray *newBlocks) {
        
        [weakSelf handleReorganizeAtBase:base oldBlocks:oldBlocks newBlocks:newBlocks];
        
    } connectedOrphans:&connectedOrphans error:&localError];
    
    if (!addedBlock) {
        if (!localError) {
            DDLogDebug(@"Block not added: %@", fullBlock);
        }
        else {
            DDLogDebug(@"Error adding block (%@): %@", localError, fullBlock);
            
            if ((localError.domain == WSErrorDomain) && (localError.code == WSErrorCodeInvalidBlock)) {
                if (error) {
                    *error = localError;
                }
            }
        }
        DDLogDebug(@"Current head: %@", self.blockChain.head);
        
        return NO;
    }
    
    [self logAddedBlock:addedBlock onFork:onFork];

    for (WSStorableBlock *block in [connectedOrphans arrayByAddingObject:addedBlock]) {
        if (![block.blockId isEqual:previousHead.blockId]) {
            [self handleAddedBlock:block];
        }
        else {
            [self handleReplacedBlock:block];
        }
    }

    return YES;
}

- (BOOL)appendFilteredBlock:(WSFilteredBlock *)filteredBlock withTransactions:(NSOrderedSet *)transactions error:(NSError *__autoreleasing *)error
{
    NSParameterAssert(filteredBlock);
    NSParameterAssert(transactions);

    NSError *localError;
    WSStorableBlock *addedBlock = nil;
    WSStorableBlock *previousHead = nil;
    __weak WSBlockChainDownloader *weakSelf = self;
    
    BOOL onFork;
    NSArray *connectedOrphans;
    previousHead = self.blockChain.head;
    addedBlock = [self.blockChain addBlockWithHeader:filteredBlock.header
                                        transactions:transactions
                                              onFork:&onFork
                                     reorganizeBlock:^(WSStorableBlock *base, NSArray *oldBlocks, NSArray *newBlocks) {
        
        [weakSelf handleReorganizeAtBase:base oldBlocks:oldBlocks newBlocks:newBlocks];
        
    } connectedOrphans:&connectedOrphans error:&localError];
    
    if (!addedBlock) {
        if (!localError) {
            DDLogDebug(@"Filtered block not added: %@", filteredBlock);
        }
        else {
            DDLogDebug(@"Error adding filtered block (%@): %@", localError, filteredBlock);
            
            if ((localError.domain == WSErrorDomain) && (localError.code == WSErrorCodeInvalidBlock)) {
                if (error) {
                    *error = localError;
                }
            }
        }
        DDLogDebug(@"Current head: %@", self.blockChain.head);
        
        return NO;
    }
    
    [self logAddedBlock:addedBlock onFork:onFork];

    for (WSStorableBlock *block in [connectedOrphans arrayByAddingObject:addedBlock]) {
        if (![block.blockId isEqual:previousHead.blockId]) {
            [self handleAddedBlock:block];
        }
        else {
            [self handleReplacedBlock:block];
        }
    }
    
    return YES;
}

#pragma mark Entity handlers

- (void)handleAddedBlock:(WSStorableBlock *)block
{
    [self.peerGroup.notifier notifyBlockAdded:block];
    
    const NSUInteger lastBlockHeight = self.downloadPeer.lastBlockHeight;
    const BOOL isDownloadFinished = (block.height == lastBlockHeight);
    
    if (isDownloadFinished) {
        for (WSPeer *peer in [self.peerGroup allConnectedPeers]) {
            if ([self needsBloomFiltering] && (peer != self.downloadPeer)) {
                DDLogDebug(@"Loading Bloom filter for peer %@", peer);
                [peer sendFilterloadMessageWithFilter:self.bloomFilter];
            }
            DDLogDebug(@"Requesting mempool from peer %@", peer);
            [peer sendMempoolMessage];
        }
        
        [self trySaveBlockChainToCoreData];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(detectDownloadTimeout) object:nil];
        });
        [self.peerGroup.notifier notifyDownloadFinished];
    }
    
    //
    
    if (self.wallet) {
        [self recoverMissedBlockTransactions:block];
    }
}

- (void)handleReplacedBlock:(WSStorableBlock *)block
{
    if (self.wallet) {
        [self recoverMissedBlockTransactions:block];
    }
}

- (void)handleReceivedTransaction:(WSSignedTransaction *)transaction
{
    BOOL didGenerateNewAddresses = NO;
    if (self.wallet && ![self.wallet registerTransaction:transaction didGenerateNewAddresses:&didGenerateNewAddresses]) {
        return;
    }
    
    if (didGenerateNewAddresses) {
        DDLogDebug(@"Last transaction triggered new addresses generation");
        
        if ([self maybeRebuildAndSendBloomFilter]) {
            [self requestOutdatedBlocks];
        }
    }
}

- (void)handleReorganizeAtBase:(WSStorableBlock *)base oldBlocks:(NSArray *)oldBlocks newBlocks:(NSArray *)newBlocks
{
    DDLogDebug(@"Reorganized blockchain at block: %@", base);
    DDLogDebug(@"Reorganize, old blocks: %@", oldBlocks);
    DDLogDebug(@"Reorganize, new blocks: %@", newBlocks);
    
    //
    // wallet should already contain transactions from new blocks, reorganize will only
    // change their parent block (thus updating wallet metadata)
    //
    // that's because after a 'merkleblock' message the following 'tx' messages are received
    // and registered anyway, even if the 'merkleblock' is later considered orphan or on fork
    // by local blockchain
    //
    // for the above reason, a reorg should never generate new addresses
    //
    
    if (!self.wallet) {
        return;
    }
    
    BOOL didGenerateNewAddresses = NO;
    [self.wallet reorganizeWithOldBlocks:oldBlocks newBlocks:newBlocks didGenerateNewAddresses:&didGenerateNewAddresses];
    
    if (didGenerateNewAddresses) {
        DDLogWarn(@"Reorganize triggered (unexpected) new addresses generation");
        
        if ([self maybeRebuildAndSendBloomFilter]) {
            [self requestOutdatedBlocks];
        }
    }
}

- (void)recoverMissedBlockTransactions:(WSStorableBlock *)block
{
    //
    // enforce registration in case we lost these transactions
    //
    // see note in [WSHDWallet isRelevantTransaction:savingReceivingAddresses:]
    //
    BOOL didGenerateNewAddresses = NO;
    for (WSSignedTransaction *transaction in block.transactions) {
        BOOL txDidGenerateNewAddresses = NO;
        [self.wallet registerTransaction:transaction didGenerateNewAddresses:&txDidGenerateNewAddresses];

        didGenerateNewAddresses |= txDidGenerateNewAddresses;
    }

    [self.wallet registerBlock:block];

    if (didGenerateNewAddresses) {
        DDLogWarn(@"Block registration triggered new addresses generation");

        if ([self maybeRebuildAndSendBloomFilter]) {
            [self requestOutdatedBlocks];
        }
    }
}

- (BOOL)maybeRebuildAndSendBloomFilter
{
    if (![self needsBloomFiltering]) {
        return NO;
    }
    
    DDLogDebug(@"Bloom filter may be outdated (height: %u, receive: %u, change: %u)",
               self.blockChain.currentHeight, self.wallet.allReceiveAddresses.count, self.wallet.allChangeAddresses.count);
    
    if ([self.wallet isCoveredByBloomFilter:self.bloomFilter]) {
        DDLogDebug(@"Wallet is still covered by current Bloom filter, not rebuilding");
        return NO;
    }
    
    DDLogDebug(@"Wallet is not covered by current Bloom filter anymore, rebuilding now");
    
    if ([self.wallet isKindOfClass:[WSHDWallet class]]) {
        WSHDWallet *hdWallet = (WSHDWallet *)self.wallet;
        
        DDLogDebug(@"HD wallet: generating %u look-ahead addresses", hdWallet.gapLimit);
        [hdWallet generateAddressesWithLookAhead:hdWallet.gapLimit];
        DDLogDebug(@"HD wallet: receive: %u, change: %u)", hdWallet.allReceiveAddresses.count, hdWallet.allChangeAddresses.count);
    }
    
    [self rebuildBloomFilter];
    
    if ([self needsBloomFiltering]) {
        if (self.blockChain.currentHeight < self.downloadPeer.lastBlockHeight) {
            DDLogDebug(@"Still syncing, loading rebuilt Bloom filter only for download peer %@", self.downloadPeer);
            [self.downloadPeer sendFilterloadMessageWithFilter:self.bloomFilter];
        }
        else {
            for (WSPeer *peer in [self.peerGroup allConnectedPeers]) {
                DDLogDebug(@"Synced, loading rebuilt Bloom filter for peer %@", peer);
                [peer sendFilterloadMessageWithFilter:self.bloomFilter];
            }
        }
    }
    
    return YES;
}

#pragma mark Macros

- (void)logAddedBlock:(WSStorableBlock *)block onFork:(BOOL)onFork
{
    NSParameterAssert(block);
    
    if ([self isSynced]) {
        if (!onFork) {
            DDLogInfo(@"New head: %@", block);
        }
        else {
            DDLogInfo(@"New fork head: %@", block);
            DDLogInfo(@"Fork base: %@", [self.blockChain findForkBaseFromHead:block]);
        }
    }
}

@end
