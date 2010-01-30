//
//  Beacon.h r69
//  Pinch Media Analytics Library
//
//  Created by Jesse Rohland on 4/6/08.
//  Copyright 2008 PinchMedia. All rights reserved.
//

#import "Beacon.h"
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import "JSON.h"
#include <stdlib.h>
#include <sqlite3.h>

// This is the key we respect in the user's preferences (NSUserDefaults)
// See http://resources.pinchmedia.com/ for more information.
#define kEnablePinchMediaStatsCollection @"kEnablePinchMediaStatsCollection"


@implementation Beacon 
// are we allowed to connect to the net? Respects wifiOnly
-(BOOL) canConnect {
	if (!wifiOnly) { return YES; }
	// boo, need to check. Reachability app has some stuff about this.
	// TODO
	return NO;
}

- (NSDictionary *) beaconData:(sqlite3_stmt *) record {
	sqlite3_step(newRecords);
// FIXME malloc is for suckers
	int *rowid = malloc(sizeof(int));
	*rowid = sqlite3_column_int(record, 1);
	NSString *event = [NSString stringWithUTF8String:(char *)sqlite3_column_text(record, 2)];
	NSString *start =  [NSDate dateWithTimeIntervalSinceReferenceDate:sqlite3_column_double(record, 3)];
	double * duration = malloc(sizeof(double));
	*duration=sqlite3_column_double(record, 4);
	
	NSDictionary * dict = [NSDictionary init];
	
	[dict setValue:(id)rowid forKey:@"client_id"];
	[dict setValue:event forKey:@"name"];
	[dict setValue:start forKey:@"recorded_at"];
	if (*duration!=0.0) {
		[dict setValue:(id)duration forKey:@"duration"];
	}
	if (locationAllowed) {
		// TODO
		[dict setValue:nil forKey:@"location"];
	}
	
	return dict;
}


// query sqlite db for outstanding records
-(NSArray *)outstandingRecords {
	NSArray * records = [NSMutableArray alloc];
	while(sqlite3_step(newRecords) == SQLITE_ROW) {
		[records arrayByAddingObject:[self beaconData:newRecords]];
	}
	return records;
}


// synchronise current state with the server
- (BOOL) synchronise {
	
	if (![self canConnect]) return YES; 
	// only one request in flight, bitte.
	if (![inFlight tryLock]) { return YES; }
	
	NSArray * records = [shared outstandingRecords];
	
	if ([records count] == 0) {[inFlight unlock]; return YES; }
	
	NSString *beaconData = [records JSONRepresentation];
	
	NSString *post = [NSString stringWithFormat:@"actions=%@&phone_spec=%@", beaconData, clientData];
	
	NSData *postData = [post dataUsingEncoding:NSASCIIStringEncoding allowLossyConversion:YES];
	NSString *postLength = [NSString stringWithFormat:@"%d",[postData length]];
	
	int startServer = random() % [servers count];
	int i = startServer;
	// yes, do loops are evil, but so are flag variables.
	
	NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:[servers objectAtIndex:i]]
														 cachePolicy:NSURLRequestUseProtocolCachePolicy
													 timeoutInterval:5.0];
	// Sending an encoded POST
	[request setHTTPMethod: @"POST"];
	[request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"content-type"];
	
	[request setHTTPBody:postData];
	[request setValue:postLength forHTTPHeaderField:@"Content-Length"];
	NSURLConnection * backtobase = [NSURLConnection alloc];
	
	do {
		i = (i+1) % [servers count];
		[request setURL:[NSURL URLWithString:[servers objectAtIndex:i]]];
		[backtobase initWithRequest:request delegate:self];
		if(backtobase) {
			[inFlight unlock];
			break;
		}
	} while (i != startServer);
	if (i==startServer) NSLog(@"couldn't connect to any host");
	return (i!=startServer);
}

- (Beacon *)appCode:(NSString *) appCode useCoreLocation:(BOOL)coreLocation useOnlyWiFi:(BOOL)wifiState {
	locationAllowed = coreLocation;
	wifiOnly = wifiState;
	inFlight = [[NSLock alloc] init];
	
	servers = [[NSArray alloc] initWithObjects:
			   @"127.0.0.1:3456"];
	responseData = [[NSMutableData data] retain];
	
	NSString *documentDirectory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
	NSString *dbFile = [documentDirectory stringByAppendingPathComponent:@"darkbird.db"];

	if (SQLITE_OK!=sqlite3_open([dbFile UTF8String],&db)) {
		NSLog(@"oops, db failed");
	}
	// create the tables - no-op if they exist already
	sqlite3_exec(db, "create table if not exists beacons (beacon TEXT, start REAL, duration REAL);", NULL, NULL, NULL);
		
	// check for SQLITE_OK here
	sqlite3_prepare_v2(db, "delete from beacons where rowid = (?NNN)", -1, &deleteStmt, NULL);
	// if it's not open-ended, duration = 0 on insert, otherwise NULL.
	sqlite3_prepare_v2(db, "insert into beacons (beacon, start, duration) VALUES (?,?,?)", -1, &insertStmt, NULL);
	sqlite3_prepare_v2(db, "select (rowid, beacon,start,duration) from beacons where duration is not NULL", -1, &newRecords, NULL);
	// arguably, this should be on start, not rowid, but it's a corner case anyway - starting
	// multiple identically named beacons and quibbling about ordering of cancelling is a bit silly,
	// especially since this can only break if we overflow rowids and have to start from scratch.
	sqlite3_prepare_v2(db, "update beacons set duration=(start-?) where name=? order by rowid asc limit 1", -1, &updateTimeStmt, NULL);
	UIDevice * device = [UIDevice currentDevice];
	NSDictionary* dict = [NSDictionary alloc];
	// TODO hash the UDID somehow, don't want to send it back in the clear.
	[dict setValue:[device uniqueIdentifier]  forKey:@"udid"];
	[dict setValue:[device model]             forKey:@"hardware"];
	[dict setValue:[device systemVersion]     forKey:@"device_os"];
	[dict setValue:appCode                    forKey:@"app_version"];
	clientData = [dict JSONRepresentation];
	return self;
}

+ (id)initAndStartBeaconWithApplicationCode:(NSString *)appCode useCoreLocation:(BOOL)coreLocation useOnlyWiFi:(BOOL)wifiState {
	shared = [Beacon alloc];
	[shared appCode:appCode useCoreLocation:coreLocation useOnlyWiFi:wifiState];
	[shared synchronise];
	return shared;
}

+ (void)endBeacon {
	[shared endBeacon];
}
		
- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
	[responseData setLength:0];	
}
		
- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
	[responseData appendData:data];
}

- (void)connection:(NSURLConnection *)connection
  didFailWithError:(NSError *)error
{
	// release the connection, and the data object
	[connection release];
	[inFlight unlock];
	// inform the user
	NSLog(@"Connection failed! Error - %@ %@",
		  [error localizedDescription],
		  [[error userInfo] objectForKey:NSErrorFailingURLStringKey]);
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{

	NSLog(@"Succeeded! Received %d bytes of data",[responseData length]);

	NSString * resp = [[NSString alloc] initWithData:responseData encoding:NSASCIIStringEncoding];

	NSArray * recorded = [[resp JSONValue] objectForKey:@"recorded_ids"];
	// boo, sqlite won't take an array to "delete from blah where id in [...]"
	// can we do anything with callbacks? would be good to have this be a quick op.
	NSEnumerator * e = [recorded objectEnumerator];
	int *i;
	while(i=(int *)[e nextObject]) {
		sqlite3_bind_int(deleteStmt, 1, *i);
		sqlite3_step(deleteStmt);
	}
	// release the connection, and the data object
	[connection release];
	[inFlight unlock];
	// data stays there, we'll use the array again.
	// [responseData release];
}


+ (id) shared {
	return shared;
}

- (void) startBeacon {
	// what on earth can this do? If we have an instance, it's already started...
	// no-op for now, TODO
}

// at least this one is more comprehensible. Shut everything down in as orderly a manner as possible.
// if we're not using in-memory data, this should be a no-op.
- (void) endBeacon {
	
//	if (![self synchronise]) {
		// log an error, something broke
//		return;
//	}
	// wait till we're done - if synchronise worked, we should be locked still.
	// semantics are slightly tricky here - should endBeacon be synchronous?
//	[inFlight lock];
	
}

- (void)startSubBeaconWithName:(NSString *)beaconName timeSession:(BOOL)trackSession {
	// I'm making the assumption that if you start two timed sessions of the same action 
	// in a row, then call endBeacon on that action name, that it ends the oldest one and the 
	// other one remains active. other possible interpretations: 
	// 1. closes both. 
	// 2. when you start a new timed session "Foo", the other session is considered to have closed with the current time. 
	// 3. when you start "Foo", either the old one or the new one is deleted and not reported.
	
	//anyway, under the first assumption, we don't look up at all, we just insert.
	

	double start = [NSDate timeIntervalSinceReferenceDate] ;

	sqlite3_bind_double(insertStmt, 1, start);
	sqlite3_bind_text(insertStmt, 2, [beaconName UTF8String], -1, SQLITE_STATIC);
	if (trackSession) {
		sqlite3_bind_null(insertStmt, 3);
	} else {
		sqlite3_bind_int(insertStmt, 3, 0);
	}
	sqlite3_step(insertStmt);
	
}
- (void)endSubBeaconWithName:(NSString *)beaconName {
	sqlite3_bind_double(updateTimeStmt, 1, [NSDate timeIntervalSinceReferenceDate]);
	sqlite3_bind_text(updateTimeStmt, 2, [beaconName UTF8String], -1, SQLITE_STATIC);
	sqlite3_step(updateTimeStmt);
}

- (void)setBeaconLocation:(CLLocation *)newLocation {
	location = newLocation;
}

@end
