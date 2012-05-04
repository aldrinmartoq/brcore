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
#ifndef __APPLE__
#include <sys/epoll.h>
#endif

#define BRLog NSLog
//#define BRLog(...)


typedef struct br_client {
    int done;
    int fd;
    struct sockaddr in_addr;
    char hbuf[NI_MAXHOST], sbuf[NI_MAXSERV];
} br_client_t;

void br_client_close(br_client_t *client);
void br_client_write(br_client_t *client, char *buff, size_t buff_len, void (^on_error)(br_client_t *));

int br_server_create(char *hostname, char *servname, void (^on_accept)(br_client_t *), void (^on_read)(br_client_t *, char *, size_t), void (^on_close)(br_client_t *));