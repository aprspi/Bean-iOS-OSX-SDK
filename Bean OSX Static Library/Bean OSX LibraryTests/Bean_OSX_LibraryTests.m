//
//  Bean_OSX_LibraryTests.m
//  Bean OSX LibraryTests
//
//  Created by Raymond Kampmeier on 2/10/14.
//  Copyright (c) 2014 Punch Through Design. All rights reserved.
//

#import <XCTest/XCTest.h>
#import "PTDBeanManager.h"

@interface Bean_OSX_LibraryTests : XCTestCase <PTDBeanManagerDelegate>

@property (nonatomic, strong) PTDBeanManager *beanManager;

@property (nonatomic, strong) void (^beanDiscovered)(PTDBean *bean);
@property (nonatomic, strong) void (^beanConnected)(PTDBean *bean);

@end

@implementation Bean_OSX_LibraryTests

- (void)setUp
{
    [super setUp];

    // Prepare BeanManager and make sure it's happy with Bluetooth powered on
    self.beanManager = [[PTDBeanManager alloc] initWithDelegate:self];
    [self delayForSeconds:1];
}

- (void)tearDown
{
    // Put teardown code here. This method is called after the invocation of each test method in the class.
    [super tearDown];
}

#pragma mark - tests

- (void)testDiscoverBean
{
    [self discoverBean];
}

- (void)testConnectBean
{
    [self connectBean];
}

#pragma mark - bean manager delegate

- (void)BeanManager:(PTDBeanManager *)beanManager didDiscoverBean:(PTDBean *)bean error:(NSError *)error
{
    NSLog(@"Discovered Bean: %@", bean);
    if (self.beanDiscovered) {
        self.beanDiscovered(bean);
    }
}

- (void)BeanManager:(PTDBeanManager *)beanManager didConnectToBean:(PTDBean *)bean error:(NSError *)error
{
    NSLog(@"Connected Bean: %@", bean);
    if (self.beanConnected) {
        self.beanConnected(bean);
    }
}

#pragma mark - test helpers

- (void)delayForSeconds:(NSInteger)seconds
{
    XCTestExpectation *waitedForXSeconds = [self expectationWithDescription:@"Waited for some specific time"];
    
    // Delay for some time (??) so that CBCentralManager connection state becomes PoweredOn
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [waitedForXSeconds fulfill];
    });
    
    [self waitForExpectationsWithTimeout:seconds + 1 handler:nil];
}

- (void)cleanup
{
    // reset blocks so no test interference occurs, since blocks are triggered by BeanManager delegates
    self.beanDiscovered = nil;
    self.beanConnected = nil;
}

- (void)discoverBean
{
    // given
    NSString *beanName = @"NEO";
    __block PTDBean *targetBean;
    NSError *error;
    
    // when
    XCTestExpectation *beanDiscover = [self expectationWithDescription:@"Target Bean found"];
    self.beanDiscovered = ^void(PTDBean *bean) {
        if ([bean.name isEqualToString:beanName]) {
            NSLog(@"Discovered target Bean: %@", bean);
            targetBean = bean;
            [beanDiscover fulfill];
        }
    };
    
    // scan
    [self.beanManager startScanningForBeans_error:&error];
    if (error) {
        XCTFail(@"startScanningForBeans should not fail");
        return;
    }
    
    [self waitForExpectationsWithTimeout:10 handler:nil];
    
    // then
    XCTAssertNotNil(targetBean, @"targetBean should not be nil");
    
    // clean up
    [self cleanup];
}

- (void)connectBean
{
    // given
    NSString *beanName = @"NEO";
    __block PTDBean *targetBean;
    NSError *error;
    
    // when
    
    XCTestExpectation *beanConnect = [self expectationWithDescription:@"Target Bean connected"];
    self.beanConnected = ^void(PTDBean *bean) {
        if ([bean.name isEqualToString:beanName]) {
            NSLog(@"Connected target Bean: %@", bean);
            [beanConnect fulfill];
        }
    };
    
    self.beanDiscovered = ^void(PTDBean *bean) {
        if ([bean.name isEqualToString:beanName]) {
            NSLog(@"Discovered target Bean: %@", bean);
            targetBean = bean;
            
            // connect
            NSError *connectError;
            [self.beanManager connectToBean:targetBean error:&connectError];
            // connectError always throws a "connection in progress" error, so don't assert that it is not nil
            // TODO: Isolate, reproduce error, figure out why this happens
        }
    };
    
    // scan
    [self.beanManager startScanningForBeans_error:&error];
    if (error) {
        XCTFail(@"startScanningForBeans should not fail");
        return;
    }
    
    // then
    [self waitForExpectationsWithTimeout:20 handler:nil];
    XCTAssertTrue(targetBean.state == BeanState_ConnectedAndValidated);
    
    // disconnect
    NSError *disconnectError;
    [self.beanManager disconnectBean:targetBean error:&disconnectError];
    XCTAssertNil(disconnectError);
    
    // clean up
    [self cleanup];
}

@end
