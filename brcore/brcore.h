//
//  brcore.h
//  brcore
//
//  Created by Aldrin Martoq on 5/3/12.
//  Copyright (c) 2012 A0. All rights reserved.
//

#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#import <dispatch/dispatch.h>

#define BRSOCKET_SERVER 0
#define BRSOCKET_CLIENT 1

typedef struct br_server {
    int type;
    int fd;
    int done;
    struct sockaddr in_addr;
    char hbuf[NI_MAXHOST], sbuf[NI_MAXSERV];
    void *on_accept;
    void *on_read;
    void *on_close;
    
} br_server_t;

typedef struct br_client {
    int type;
    int fd;
    int done;
    struct sockaddr in_addr;
    char hbuf[NI_MAXHOST], sbuf[NI_MAXSERV];
    br_server_t *s;
} br_client_t;

#define BR_LOG_TRA_ENABLED 0
#define BR_LOG_DEB_ENABLED 0
#define BR_LOG_INF_ENABLED 1
#define BR_LOG_ERR_ENABLED 1

void br_log(char level, char *fmt, ...);
void br_log_trace(char *fmt, ...);
void br_log_debug(char *fmt, ...);
void br_log_info(char *fmt, ...);
void br_log_error(char *fmt, ...);

br_server_t *br_server_create(char *hostname, char *servname, void (^on_accept)(br_client_t *), void (^on_read)(br_client_t *, char *, size_t), void (^on_close)(br_client_t *));
void br_client_close(br_client_t *c);
void br_client_write(br_client_t *c, char *buff, size_t buff_len, void (^on_error)(br_client_t *));

void br_runloop();