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

- (NSMutableDictionary *) beaconData {
	// sqlite3_step(newRecords);
// FIXME malloc is for suckers

	int rowid = sqlite3_column_int(newRecords, 0);
	NSString *event = [NSString stringWithUTF8String:(char *)sqlite3_column_text(newRecords, 1)];
	NSLog(@"Beacon name %@", event);
	NSString *start =  [NSDate dateWithTimeIntervalSinceReferenceDate:sqlite3_column_double(newRecords, 2)];
	double duration=sqlite3_column_double(newRecords, 3);
	NSMutableDictionary * dict = [[NSMutableDictionary alloc] init];
    [dict setValue:event forKey:@"name"];
	[dict setValue:[NSNumber numberWithInteger:rowid] forKey:@"client_id"];

	// FIXME
	[dict setValue:@"dummy" forKey: @"recorded_at"];
	
	if (duration!=0.0) {
		[dict setValue:[NSNumber numberWithDouble:duration] forKey:@"duration"];
	}
	if (locationAllowed) {
		// TODO
		[dict setValue:nil forKey:@"location"];
	}

	[dict retain];	
	return dict;
}

int check_sql(NSString * context, int errCode) {
	if (errCode != SQLITE_OK && errCode != SQLITE_ROW && errCode != SQLITE_DONE) {
		NSLog(@"oops, weird result at %@: %d", context, errCode);
	}
	return errCode;
}

// query sqlite db for outstanding records
-(NSArray *)outstandingRecords {
	NSLog(@"Finding records");
	NSMutableArray * records = [[[NSMutableArray alloc] init] retain];
	while(check_sql(@"new records", sqlite3_step(newRecords)) == SQLITE_ROW) {
		NSLog(@"pulling out a record");
		[records addObject:[self beaconData]];
	}
	sqlite3_reset(newRecords);
	NSLog(@"Got %d records", [records count]);
	return records;
}


// synchronise current state with the server
- (BOOL) synchronise {
	NSLog(@"sync requested");
	if (![self canConnect]) return YES; 
	// only one request in flight, bitte.
	if (![inFlight tryLock]) {
		NSLog(@"couldn't lock inflight");
		return YES; 
	}
	NSLog(@"locked inflight:%@", inFlight);
	
	NSArray * records = [shared outstandingRecords];
	int rc = [records count];
	NSLog(@"got %d records",rc);
	if (rc == 0) {
		NSLog(@"Nothing to report");
		[inFlight unlock];
		return YES; 
	}
	NSLog(@"here?");
	NSString *beaconData = [records JSONRepresentation];
		// NSLog(@"ACtions: %@", beaconData);
	NSLog(@"Ready to post: %@",clientData);
	NSLog(@"Ready to post: %@, %@", beaconData, clientData);
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
			NSLog(@"Trying to connect to %@", [servers objectAtIndex:i]);
			//NSLog(@"lock state: %@", inFlight);
			//[inFlight unlock];
			// NSLog(@"unlocked inflight: %@", inFlight);
			return YES;
		}
		NSLog(@"Couldn't connect to %@", [servers objectAtIndex:i]);
	} while (i != startServer);
	NSLog(@"couldn't connect to any host");
	return NO;
}


- (Beacon *)appCode:(NSString *) appCode useCoreLocation:(BOOL)coreLocation useOnlyWiFi:(BOOL)wifiState {
	NSLog(@"starting");
	locationAllowed = coreLocation;
	wifiOnly = wifiState;
	inFlight = [[NSLock alloc] init];
	[inFlight setName:@"in flight"];
	NSLog(@"got inFlight");
	servers = [[NSArray alloc] initWithObjects:
			   @"http://127.0.0.1:4567/report",nil]; // FIXME https for prod. pull servers out.
	NSLog(@"got the servers");
	responseData = [[NSMutableData data] retain];
	NSLog(@"got the data");
	NSString *documentDirectory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
	NSString *dbFile = [documentDirectory stringByAppendingPathComponent:@"darkbird.db"];
	NSLog(@"got the dir");
	if (SQLITE_OK!=sqlite3_open([dbFile UTF8String],&db)) {
		NSLog(@"oops, db failed");
	}
	// create the tables - no-op if they exist already
//	check_sql(@"creation", sqlite3_exec(db, "drop table beacons;", NULL, NULL, NULL));
	check_sql(@"creation", sqlite3_exec(db, "create table if not exists beacons (ROWID INTEGER PRIMARY KEY autoincrement, beacon TEXT, start REAL, duration REAL);", NULL, NULL, NULL));
	

	// check for SQLITE_OK here
	check_sql(@"del", sqlite3_prepare_v2(db, "delete from beacons where ROWID = ?", -1, &deleteStmt, NULL));
	// if it's not open-ended, duration = 0 on insert, otherwise NULL.
	check_sql(@"insert", sqlite3_prepare_v2(db, "insert into beacons (beacon, start, duration) VALUES (?,?,?)", -1, &insertStmt, NULL));
	check_sql(@"select", sqlite3_prepare_v2(db, "select ROWID, beacon,start,duration from beacons where duration is not NULL", -1, &newRecords, NULL));
	// arguably, this should be on start, not rowid, but it's a corner case anyway - starting
	// multiple identically named beacons and quibbling about ordering of cancelling is a bit silly,
	// especially since this can only break if we overflow rowids and have to start from scratch.
    //check_sql(@"update", sqlite3_prepare_v2(db, "update beacons set duration=start-? where beacon=? order by ROWID limit 1", -1, &updateTimeStmt, NULL));
	check_sql(@"update", sqlite3_prepare_v2(db, "update beacons set duration=start-? where beacon=?", -1, &updateTimeStmt, NULL));
	check_sql(@"count", sqlite3_prepare_v2(db, "select count(*) from beacons;", -1, &countStmt, NULL));
	UIDevice * device = [UIDevice currentDevice];
	NSDictionary* dict = [NSDictionary dictionaryWithObjectsAndKeys:
									[device uniqueIdentifier], @"udid",
									[device model], @"hardware",
									[device systemVersion], @"device_os",
									appCode, @"app_version",
						  nil];
										
		
	// TODO hash the UDID somehow, don't want to send it back in the clear.
	clientData = [[dict JSONRepresentation] retain];
	NSLog(@"initialised,, bitches");
	return self;
}

+ (id)initAndStartBeaconWithApplicationCode:(NSString *)appCode useCoreLocation:(BOOL)coreLocation useOnlyWiFi:(BOOL)wifiState {
	shared = [Beacon alloc];
	[shared appCode:appCode useCoreLocation:coreLocation useOnlyWiFi:wifiState];
		// [shared synchronise];
	return shared;
}

+ (void)endBeacon {
	[shared endBeacon];
}
		
- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
	NSLog(@"initial response");
	[responseData setLength:0];	
}
		
- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
	NSLog(@"received data");
	[responseData appendData:data];
}

- (void)connection:(NSURLConnection *)connection
  didFailWithError:(NSError *)error
{
	// release the connection, and the data object
	[connection release];
	// inform the user
	NSLog(@"Connection failed! Error - %@ %@",
		  [error localizedDescription],
		  [[error userInfo] objectForKey:NSErrorFailingURLStringKey]);
	[inFlight unlock];
	
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{

	NSLog(@"Succeeded! Received %d bytes of data",[responseData length]);

	NSString * resp = [[NSString alloc] initWithData:responseData encoding:NSASCIIStringEncoding];
    NSLog(@"Response: %@", resp);
	NSArray * recorded = [[resp JSONValue] objectForKey:@"recorded_ids"];
	// boo, sqlite won't take an array to "delete from blah where id in [...]"
	// can we do anything with callbacks? would be good to have this be a quick op.
	NSEnumerator * e = [recorded objectEnumerator];
	id i;
	while(i=[e nextObject]) {
		NSLog(@"Really deleting %d...",[i intValue]);
		check_sql(@"bind",sqlite3_bind_int(deleteStmt, 1, [i intValue] ));
		check_sql(@"deleting row", sqlite3_step(deleteStmt));
		sqlite3_reset(deleteStmt);
		sqlite3_step(countStmt);
		NSLog(@"%d rows left in db", sqlite3_column_int(countStmt, 0));
		sqlite3_reset(countStmt);
	}
	// release the connection, and the data object
	// [connection release];
	NSLog(@"unlocking %@", inFlight);
	[inFlight unlock];
	NSLog(@"unlocked %@", inFlight);
	// data stays there, we'll use the array again.
	// [responseData release];
	// aaaaand go again
	[shared synchronise];
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

	NSLog(@"bindin text %s", [beaconName UTF8String]);
	if(SQLITE_OK != sqlite3_bind_text(insertStmt, 1, [beaconName UTF8String], -1, SQLITE_STATIC)) {
		NSLog(@"Couldn't bind text %s", [beaconName UTF8String]);
		return;
	}
	if (SQLITE_OK != sqlite3_bind_double(insertStmt, 2, start) ) {
		NSLog(@"Couldn't bind the double");
		return;
	}
	
	if (trackSession) {
		sqlite3_bind_null(insertStmt, 3);
	} else {
		sqlite3_bind_int(insertStmt, 3, 0);
	}
	check_sql(@"insertion", sqlite3_step(insertStmt));
	sqlite3_reset(insertStmt);
	[self synchronise];
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
