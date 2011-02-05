#import "SFTPConnectionPool.h"
#import "logging.h"

@implementation SFTPConnectionPool

- (SFTPConnectionPool *)init
{
	self = [super init];
	if (self)
		connections = [[NSMutableDictionary alloc] init];
	return self;
}

+ (SFTPConnectionPool *)sharedPool
{
	static SFTPConnectionPool *sharedPool = nil;
	if (sharedPool == nil)
		sharedPool = [[SFTPConnectionPool alloc] init];
	return sharedPool;
}

- (SFTPConnection *)connectionWithHost:(NSString *)hostname user:(NSString *)username error:(NSError **)outError
{
	NSString *key;
	if ([username length] > 0)
		key = [NSString stringWithFormat:@"%@@%@", username, hostname];
	else
		key = hostname;
	SFTPConnection *conn = [connections objectForKey:key];

	if (conn && [conn closed]) {
		[connections removeObjectForKey:key];
		conn = nil;
	}

	if (conn == nil) {
		conn = [[SFTPConnection alloc] initWithHost:hostname user:username error:outError];
		if (conn != nil)
			[connections setObject:conn forKey:key];
	}

	return conn;
}

- (SFTPConnection *)connectionWithURL:(NSURL *)url error:(NSError **)outError
{
	return [self connectionWithHost:[url host] user:[url user] error:outError];
}

@end

