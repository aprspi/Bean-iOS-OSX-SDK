//
//  OADDevice.m
//  BleArduino
//
//  Created by Raymond Kampmeier on 8/16/13.
//  Copyright (c) 2013 Punch Through Design. All rights reserved.
//

#import "OadProfile.h"

// OAD implementation based on http://processors.wiki.ti.com/images/8/82/OAD_for_CC254x.pdf

#define SERVICE_OAD                     @"0xF000FFC0-0451-4000-B000-000000000000"
#define CHARACTERISTIC_OAD_IDENTIFY     @"0xF000FFC1-0451-4000-B000-000000000000"
#define CHARACTERISTIC_OAD_BLOCK        @"0xF000FFC2-0451-4000-B000-000000000000"

#define ERROR_DOMAIN                    @"OAD"
#define ERROR_CODE                      100

#define WATCHDOG_TIMER_INTERVAL         (2)

typedef NS_ENUM(NSUInteger, OADState) {
    OADStateIdle,
    OADStateEnableNotify,
    OADStateSentNewHeader,
    OADStateSendingPackets,
    OADStateWaitForCompletion
};

typedef struct {
    UInt16 crc0;
    UInt16 crc1;       // CRC-shadow must be 0xFFFF.
    UInt16 ver;        // User-defined Image Version Number - default logic uses simple a '<' comparison to start an OAD.
    UInt16 len;        // Image length in 4-byte blocks (i.e. HAL_FLASH_WORD_SIZE blocks).
    UInt8  uid[4];     // User-defined Image Identification bytes.
    UInt8  res[4];     // Reserved space for future use.
} img_hdr_t;

typedef struct {
    UInt16  ver;
    UInt16  len;
    UInt8   uid[4];
    UInt8   res[4];
} request_oad_header_t;

typedef struct {
    UInt16  ver;
    UInt16  len;
    UInt8   uid[4];
} response_oad_header_t;

typedef UInt8 data_block_t[16];

typedef struct {
    UInt16          nbr;
    data_block_t    block;
} oad_packet_t;

@interface OadProfile ()

@property (strong, nonatomic)   CBService           *serviceOAD;
@property (strong, nonatomic)   CBCharacteristic    *characteristicOADBlock;
@property (strong, nonatomic)   CBCharacteristic    *characteristicOADIdentify;

@property (strong, nonatomic)   NSData              *imageData;
@property (strong, nonatomic)   NSMutableArray      *firmwareImages;

@property (nonatomic)           OADState            oadState;
@property (strong, nonatomic)   NSTimer             *watchdogTimer;
@property (nonatomic)           BOOL                watchdogSet;
@property (strong, nonatomic)   NSDate              *downloadStartDate;
@property (nonatomic)           float               leastSeconds;

@property (nonatomic)           int16_t              nextBlock;
@property (nonatomic)           int16_t              nextBlockRequest;
@property (nonatomic)           int16_t              totalBlocks;

@end

@implementation OadProfile
@dynamic delegate; // Delegate is already synthesized by BleProfile subclass

+(void)load
{
    [super registerProfile:self serviceUUID:SERVICE_OAD];
}

#pragma mark - NSObject

- (instancetype)initWithService:(CBService*)service
{
    self = [super init];
    if (self) {
        peripheral = service.peripheral;
        self.oadState = OADStateIdle;
        self.serviceOAD = service;
    }
    return self;
}

#pragma mark - PTDOADProfile

- (BOOL)updateFirmwareWithImagePaths:(NSArray*)firmwareImages
{
    
    PTDLog(@"OAD updating firmware with image paths: %@", firmwareImages);
    
    if (peripheral.state != CBPeripheralStateConnected) {
        if ([self.delegate respondsToSelector:@selector(device:completedFirmwareUploadWithError:)]) {
            [self.delegate device:self completedFirmwareUploadWithError:[NSError errorWithDomain:ERROR_DOMAIN
                                                                                            code:ERROR_CODE
                                                                                        userInfo:@{NSLocalizedDescriptionKey:@"Device is not connected"}]];
        }
        return NO;
    }
    
    if (self.oadState != OADStateIdle) {
        if ([self.delegate respondsToSelector:@selector(device:completedFirmwareUploadWithError:)]) {
            [self.delegate device:self completedFirmwareUploadWithError:[NSError errorWithDomain:ERROR_DOMAIN
                                                                                            code:ERROR_CODE
                                                                                        userInfo:@{NSLocalizedDescriptionKey:@"Download already started"}]];
        }
        return NO;
    }
    
    self.firmwareImages = [NSMutableArray arrayWithArray:firmwareImages];
    
    self.watchdogSet = NO;
    self.watchdogTimer = [NSTimer scheduledTimerWithTimeInterval:WATCHDOG_TIMER_INTERVAL
                                                          target:self
                                                        selector:@selector(watchdogTimerFired:)
                                                        userInfo:nil
                                                         repeats:YES];
    
    self.leastSeconds = FLT_MAX;
    
    [self enableNotify];
    
    return YES;
}



#pragma mark - BleProfile
-(void)validate
{
    [peripheral discoverCharacteristics:@[[CBUUID UUIDWithString:CHARACTERISTIC_OAD_IDENTIFY],
                                          [CBUUID UUIDWithString:CHARACTERISTIC_OAD_BLOCK]]
                             forService:self.serviceOAD];
}
- (BOOL)isValid:(NSError**)error
{
    return (self.characteristicOADIdentify &&
            self.characteristicOADBlock);
}

#pragma mark - CBPeripheralDelegate

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error
{
    self.watchdogSet = NO;
    if (!error) {
        if (![self processCharacteristics]) {
            PTDLog(@"Did not find all OAD characteristics\n");
        }
    } else {
        PTDLog(@"Error discovering characteristics: %@", [error localizedDescription]);
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error
{
    self.watchdogSet = NO;
    if (!error) {
        if (self.oadState == OADStateEnableNotify) {
            if (self.characteristicOADBlock.isNotifying && self.characteristicOADIdentify.isNotifying) {
                [self beginOAD];
            }
        }
    }
}

- (void)peripheral:(CBPeripheral *)aPeripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error
{
    self.watchdogSet = NO;
    if ([characteristic isEqual:self.characteristicOADBlock]) {
        UInt16 requestedBlock = CFSwapInt16LittleToHost(*((UInt16 *)characteristic.value.bytes));
        switch (self.oadState) {
            case OADStateSentNewHeader:
                PTDLog(@"Device accepts transfer\n");
                self.oadState = OADStateSendingPackets;
                self.nextBlock = 0;
                self.nextBlockRequest = 0;
                // Fall through
                
            case OADStateSendingPackets:
            case OADStateWaitForCompletion:
                [self sendBlocks:requestedBlock];
                break;
                
            default:
                PTDLog(@"Unexpected value update for Block characteristic in state %tu\n", self.oadState);
                break;
        }
    } else if ([characteristic isEqual:self.characteristicOADIdentify]) {
        switch (self.oadState) {
                
            case OADStateSentNewHeader:

                [self beginOAD];        // Try next firmware image
                break;
                
            default:
                PTDLog(@"Unexpected value update for Identity characteristic in state %tu\n", self.oadState);
                break;
        }
    }
}

#pragma mark - Internal


- (BOOL)processCharacteristics
{
    if (self.serviceOAD.characteristics) {
        CBUUID *oadIdentityUUID = [CBUUID UUIDWithString:CHARACTERISTIC_OAD_IDENTIFY];
        CBUUID *oadBlockUUID =  [CBUUID UUIDWithString:CHARACTERISTIC_OAD_BLOCK];
        for (CBCharacteristic *characteristic in self.serviceOAD.characteristics) {
            if (!self.characteristicOADIdentify && [characteristic.UUID isEqual:oadIdentityUUID]) {
                self.characteristicOADIdentify = characteristic;
            }
            if (!self.characteristicOADBlock && [characteristic.UUID isEqual:oadBlockUUID]) {
                self.characteristicOADBlock = characteristic;
            }
        }
    }
    
    BOOL valid = self.characteristicOADBlock && self.characteristicOADIdentify;
    if (valid) {
        PTDLog(@"%@: OAD found", self.class.description);
        [self __notifyValidity];
    }
    
    return valid;
}

// Send the requested block number to the OAD Target
-(void)sendOneBlock:(UInt16)block
{
    data_block_t    *imageBlocks = (data_block_t *)self.imageData.bytes;
    NSMutableData *data = [NSMutableData dataWithLength:sizeof(oad_packet_t)];
    oad_packet_t *packet = (oad_packet_t *)data.bytes;
    packet->nbr = CFSwapInt16HostToLittle(block);
    memcpy(&packet->block, &(imageBlocks[block]), sizeof(data_block_t));
    [peripheral writeValue:data forCharacteristic:self.characteristicOADBlock type:CBCharacteristicWriteWithoutResponse];
}

// Every time we receive a block request from the OAD Target, add more blocks to the queue if there is room
// Check for re-requests that indicate a block was missed. Send the missed block and re-fill the queue with the
// subsequent blocks.
#define BLOCKS_INFLIGHT 18
- (void)sendBlocks:(UInt16)requestedBlock
{
    // A block was re-requested, it must have been lost
    // Expect to see a re-request for every block that was already in flight, attempt to ignore
    if (requestedBlock < self.nextBlockRequest) {
        PTDLog(@"OAD block %d lost in transit! Resending.", requestedBlock);
        self.nextBlockRequest -= self.nextBlock - requestedBlock - 1; // Compensate for in flight blocks
        self.nextBlock = requestedBlock;
        self.oadState = OADStateSendingPackets;
    }
    self.nextBlockRequest++;
    
    // Batch together the sending of up to 18 blocks, but not after every request
    if( self.nextBlock - requestedBlock < BLOCKS_INFLIGHT/4 ) {

        // Update the delegate on our progress
        if (self.nextBlock) {
            NSNumber *percentage = [NSNumber numberWithFloat:(self.nextBlock * 1.0) / self.totalBlocks];
            float secondsSoFar = -[self.downloadStartDate timeIntervalSinceNow];
            self.leastSeconds = (secondsSoFar / self.nextBlock) * (self.totalBlocks - self.nextBlock);
            NSNumber *seconds = [NSNumber numberWithFloat:self.leastSeconds];
            [self.delegate device:self OADUploadTimeLeft:seconds withPercentage:percentage];
        } else {
            self.downloadStartDate = [NSDate date];
        }
        
        // Send the blocks
        while( self.nextBlock - requestedBlock < BLOCKS_INFLIGHT && self.nextBlock < self.totalBlocks ){
            [self sendOneBlock:self.nextBlock];
            self.nextBlock++;
        }
        
    }

    // Watch for last block
    if ( self.nextBlock == self.totalBlocks) {
        self.oadState = OADStateWaitForCompletion; // Signal the watchdog timer that we expect to timeout, allows OAD Target to re-request last packet
    }
}

- (void)enableNotify
{
    self.oadState = OADStateEnableNotify;
    
    if (self.characteristicOADBlock.isNotifying && self.characteristicOADIdentify.isNotifying) {
        // Already enabled
        [self beginOAD];
    } else {
        if (!self.characteristicOADBlock.isNotifying) {
            [peripheral setNotifyValue:YES forCharacteristic:self.characteristicOADBlock];
        }
        if (!self.characteristicOADIdentify.isNotifying) {
            [peripheral setNotifyValue:YES forCharacteristic:self.characteristicOADIdentify];
        }
    }
}

- (void)beginOAD
{
    if ( [self.firmwareImages count] > 0 ) {
        NSString *filename = self.firmwareImages[0];
        PTDLog(@"Offering firmware image %@", filename);
        [self.firmwareImages removeObjectAtIndex:0];
        
        NSError* error = nil;
        self.imageData = [NSData dataWithContentsOfFile:filename options:0 error:&error];
        
        if (error) {
            PTDLog(@"Couldn't load firmware file: %@", error);
        }
        
        if (!self.imageData) {
            [self completeWithError:[NSError errorWithDomain:ERROR_DOMAIN
                                                        code:ERROR_CODE
                                                    userInfo:@{NSLocalizedDescriptionKey:@"Couldn't load firmware image."}]];
            return;
        }
        
        
        self.totalBlocks = self.imageData.length / sizeof(data_block_t);
        img_hdr_t *imageHeader = (img_hdr_t *)self.imageData.bytes;
        
        NSMutableData *data = [NSMutableData dataWithLength:sizeof(request_oad_header_t)];
        request_oad_header_t   *request = (request_oad_header_t *)data.bytes;
        request->ver = imageHeader->ver;
        request->len = imageHeader->len;
        memcpy(&request->uid, &imageHeader->uid, sizeof(request->uid));
        UInt16  reserved[] = {CFSwapInt16HostToLittle(12), CFSwapInt16HostToLittle(15)};
        memcpy(&request->res, reserved, sizeof(request->res));
            
        self.oadState = OADStateSentNewHeader;
            
        [peripheral writeValue:data forCharacteristic:self.characteristicOADIdentify type:CBCharacteristicWriteWithoutResponse];
    } else {
        [self completeWithError:[NSError errorWithDomain:ERROR_DOMAIN
                                                    code:ERROR_CODE
                                                userInfo:@{NSLocalizedDescriptionKey:@"Device rejected all available firmware versions."}]];
        PTDLog(@"Device rejected all available firmware versions.");
    }
}

- (void)cancel
{
    if (self.oadState != OADStateIdle) {
        [self completeWithError:NULL];
    }
}

- (void)completeWithError:(NSError *)error
{
    if (error) PTDLog(@"OAD completed with error: %@", error);
    self.oadState = OADStateIdle;
    self.downloadStartDate = nil;
    self.imageData = nil;
    [self.watchdogTimer invalidate];
    self.watchdogTimer = nil;
    [peripheral setNotifyValue:NO forCharacteristic:self.characteristicOADBlock];
    [peripheral setNotifyValue:NO forCharacteristic:self.characteristicOADIdentify];
    if ([self.delegate respondsToSelector:@selector(device:completedFirmwareUploadWithError:)]) {
        [self.delegate device:self completedFirmwareUploadWithError:error];
    }
}

- (void)watchdogTimerFired:(NSTimer *)timer
{
    if (self.oadState == OADStateIdle) {
        // watchdog should never be running in idle.
        PTDLog(@"OAD State idle.");
        [timer invalidate];
        self.watchdogTimer = nil;
    }
    
    if (self.watchdogSet) {
        NSError *error;
        switch (self.oadState) {
            case OADStateWaitForCompletion:
                PTDLog(@"OAD completed in %f seconds", -[self.downloadStartDate timeIntervalSinceNow]-WATCHDOG_TIMER_INTERVAL);
                break;
                
            case OADStateEnableNotify:
                error = [NSError errorWithDomain:ERROR_DOMAIN
                                            code:ERROR_CODE
                                        userInfo:@{NSLocalizedDescriptionKey:@"Timeout configuring OAD characteristics."}];
                break;
                
            case OADStateSendingPackets:
                if (self.nextBlockRequest == 1) {
                    PTDLog(@"Bean is resetting to small OAD-only image.");
                } else {
                    error = [NSError errorWithDomain:ERROR_DOMAIN
                                                code:ERROR_CODE
                                            userInfo:@{NSLocalizedDescriptionKey:@"Timeout sending firmware."}];
                }
                break;
                
            default:
                error = [NSError errorWithDomain:ERROR_DOMAIN
                                            code:ERROR_CODE
                                        userInfo:@{NSLocalizedDescriptionKey:@"Unexpected watchdog timeout."}];
                break;
        }

        [self completeWithError:error];
    } else {
        self.watchdogSet = YES;
    }
}

@end
