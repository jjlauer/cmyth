//
//  api.m
//  cmyth
//
//  Created by Jon Gettler on 12/17/09.
//  Copyright 2009 __MyCompanyName__. All rights reserved.
//

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include <cmyth/cmyth.h>
#include <refmem/refmem.h>

#import "api.h"

@implementation cmythProgram

-(cmythProgram*)program:(cmyth_proginfo_t)program
{
	self = [super init];

	prog = program;

	return self;
}

-(cmyth_proginfo_t)proginfo
{
	return prog;
}

#define proginfo_method(type)					\
-(NSString*)type						\
{								\
	char *type;						\
	NSString *result = nil;					\
								\
	type = cmyth_proginfo_##type(prog);			\
								\
	if (type != NULL) {					\
		result = [NSString stringWithUTF8String:type];	\
		ref_release(type);				\
	}							\
								\
	return result;						\
}

proginfo_method(title)
proginfo_method(subtitle)
proginfo_method(description)
proginfo_method(category)

-(void) dealloc
{
	ref_release(prog);

	[super dealloc];
}

@end

@implementation cmythFile

typedef struct {
	char *command;
	char *file;
	long long start;
	long long end;
} url_t;

static url_t*
read_header(int fd)
{
	char buf[512];
	char request[512];
	char line[512];
	int l = 0;
	url_t *u;
	char *p, *b, *o;
	static int seen = 0;

	read(fd, buf, sizeof(buf));

	u = (url_t*)malloc(sizeof(url_t));
	memset(u, 0, sizeof(*u));

	memset(request, 0, sizeof(request));
	memset(line, 0, sizeof(line));

	b = strstr(buf, "\r\n");
	*b = '\0';
	strcpy(request, buf);
	*b = '\r';
	b += 2;

	u->command = strdup(request);
	if ((p=strchr(u->command, ' ')) != NULL) {
		*(p++) = '\0';
		u->file = p;
		if ((p=strchr(p, ' ')) != NULL) {
			*(p++) = '\0';
		}
	}

	while (1) {
		char *field, *value;

		o = b;
		b = strstr(o, "\r\n");
		*b = '\0';
		strcpy(line, o);
		*b = '\r';
		b += 2;
		if (*b == '\r') {
			break;
		}

		if (strcmp(line, "\r\n") == 0) {
			break;
		}

		field = line;
		if ((value=strchr(field, ':')) != NULL) {
			*(value++) = '\0';
		}

		if (strcasecmp(field, "range") == 0) {
			char *start, *end;

			start = strchr(value, '=');
			start++;
			end = strchr(start, '-');
			*(end++) = '\0';

			u->start = strtoll(start, NULL, 0);
			u->end = strtoll(end, NULL, 0);
		}

		l++;
	}

	seen++;

	return u;
}

static void
handler(int sig)
{
}

static int
my_write(int fd, char *buf, int len)
{
	int tot = 0;
	int n, err;

	while (tot < len) {
		n = write(fd, buf+tot, len-tot);
		err = errno;
		if (n < 0) {
			break;
		}

		tot += n;
	}

	return tot;
}

static int
send_header(int fd, url_t *u, long long length)
{
	long long size = u->end - u->start + 1;
	char buf[512];

	memset(buf, 0, sizeof(buf));

	sprintf(buf, "HTTP/1.1 206 Partial Content\r\n");
	sprintf(buf+strlen(buf), "Server: mvpmc\r\n");
	sprintf(buf+strlen(buf), "Accept-Ranges: bytes\r\n");
	sprintf(buf+strlen(buf), "Content-Length: %lld\r\n", size);
	sprintf(buf+strlen(buf), "Content-Range: bytes %lld-%lld/%lld\r\n",
		u->start, u->end, length);
	sprintf(buf+strlen(buf), "Connection: close\r\n");
	sprintf(buf+strlen(buf), "\r\n");

	if (my_write(fd, buf, strlen(buf)) != strlen(buf)) {
		return -1;
	}

	return 0;
}

static long long
send_data(int fd, url_t *u, cmyth_file_t file)
{
	unsigned char *buf;
	unsigned long long pos;
	long long wrote = 0;

#define BSIZE (8*1024)
	if ((buf=(unsigned char*)malloc(BSIZE)) == NULL) {
		return;
	}

	pos = cmyth_file_seek(file, u->start, SEEK_SET);

	while (pos <= (u->end)) {
		int size, tot, len;

		size = ((u->end - pos) >= BSIZE) ? BSIZE : (u->end - pos + 1);

		len = cmyth_file_request_block(file, size);

		tot = 0;
		while (tot < len) {
			int n;
			n = cmyth_file_get_block(file, buf+tot, len-tot);
			if (n <= 0) {
				goto err;
			}
			tot += n;
		}

		if (my_write(fd, buf, len) != len) {
			break;
		}

		wrote += len;

		pos += len;
	}

err:
	free(buf);

	return wrote;
}

-(void)server
{
	int fd;
	int attempts = 0;
	long long wrote = 0;

	while (1) {
		url_t *u;

		if (listen(sockfd, 5) != 0) {
			return;
		}

		if ((fd=accept(sockfd, NULL, NULL)) < 0) {
			return;
		}

		int set = 1;
		setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, (void *)&set, sizeof(int));

		attempts++;

		u = read_header(fd);

		if (strcasecmp(u->command, "GET") == 0) {
			if (send_header(fd, u, length) == 0) {
				wrote += send_data(fd, u, file);
			}
		}

		close(fd);
	}
}

static int
create_socket(int *f, int *p)
{
	int fd, port, rc;
	int attempts = 0;
	struct sockaddr_in sa;

	if ((fd=socket(PF_INET, SOCK_STREAM, IPPROTO_TCP)) < 0) {
		return -1;
	}

	int set = 1;
	setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, (void *)&set, sizeof(int));

	do {
		port = (random() % 32768) + 5001;

		memset(&sa, 0, sizeof(sa));

		sa.sin_family = AF_INET;
		sa.sin_port = htons(port);
		sa.sin_addr.s_addr = INADDR_ANY;

		rc = bind(fd, &sa, sizeof(sa));
	} while ((rc != 0) && (attempts++ < 100));

	if (rc != 0) {
		close(fd);
		return -1;
	}

	*f = fd;
	*p = port;

	return 0;
}

-(cmythFile*)openWith:(cmythProgram*)program
{
	int tcp_control = 4096;
	int tcp_program = 128*1024;
	int port;
	char *host;
	cmyth_proginfo_t prog;

	if (create_socket(&sockfd, &portno) != 0) {
		return nil;
	}

	prog = [program proginfo];

	if ((host=cmyth_proginfo_host(prog)) == NULL) {
		goto err;
	}

	if ((port=cmyth_proginfo_port(prog)) < 0) {
		goto err;
	}

	if ((conn=cmyth_conn_connect_ctrl(host, port, 16*1024,
					  tcp_control)) == NULL) {
		goto err;
	}

#define MAX_BSIZE	(256*1024*3)
	if ((file=cmyth_conn_connect_file(prog, conn, MAX_BSIZE,
					  tcp_program)) == NULL) {
		goto err;
	}

	length = cmyth_proginfo_length(prog);

	self = [super init];

	[NSThread detachNewThreadSelector:@selector(server)
		  toTarget:self withObject:nil];

	return self;

err:
	close(sockfd);

	return nil;
}

-(int)portNumber
{
	return portno;
}

@end

@implementation cmythProgramList

-(cmythProgramList*)control:(cmyth_conn_t)control
{
	cmyth_proglist_t list;
	int i, count;

	if ((list=cmyth_proglist_get_all_recorded(control)) == NULL) {
		return nil;
	}

	self = [super init];

	count = cmyth_proglist_get_count(list);

	array = [[NSMutableArray alloc] init];

	for (i=0; i<count; i++) {
		cmyth_proginfo_t prog;
		cmythProgram *program;

		prog = cmyth_proglist_get_item(list, i);
		program = [[cmythProgram alloc] program:prog];

		[array addObject: program];
	}

	return self;
}

-(cmythProgram*)progitem:(int)n
{
	return [array objectAtIndex:n];
}

-(int) count
{
	return [array count];
}

-(void) dealloc
{
	[array release];
	[super dealloc];
}

@end

@implementation cmyth

-(cmyth*) server:(NSString*) server
	    port: (unsigned short) port
{
	cmyth_conn_t c, e;
	char *host = [server UTF8String];
	int len = 16*1024;
	int tcp = 4096;

	if (port == 0) {
		port = 6543;
	}

	if (host == NULL) {
		return nil;
	}

	if ((c=cmyth_conn_connect_ctrl(host, port, len, tcp)) == NULL) {
		return nil;
	}
	if ((e=cmyth_conn_connect_event(host, port, len, tcp)) == NULL) {
		return nil;
	}

	self = [super init];

	if (self) {
		control = c;
		event = e;
	} else {
		control = NULL;
		event = NULL;
	}

	return self;
}

-(int) protocol_version
{
	return cmyth_conn_get_protocol_version(control);
}

-(cmythProgramList*)programList
{
	cmythProgramList *list;

	list = [[cmythProgramList alloc] control:control];

	return list;
}

-(int)getEvent:(cmyth_event_t*)event
{
	struct timeval tv;

	tv.tv_sec = 0;
	tv.tv_usec = 0;

	if (cmyth_event_select(self->event, &tv) > 0) {
		*event = cmyth_event_get(self->event, NULL, 0);
		return 0;
	}

	return -1;
}

-(void) dealloc
{
	ref_release(control);
	ref_release(event);

	[super dealloc];
}

@end
