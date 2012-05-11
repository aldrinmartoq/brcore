//
//  main.m
//  brcore
//
//  Created by Aldrin Martoq on 5/3/12.
//  Copyright (c) 2012 A0. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "brcore.h"
#import "http_parser.h"

static http_parser_settings settings;

unsigned long long count = 0;
unsigned long long closed = 0;

struct local {
    http_parser parser;
    unsigned long long number;
    char url[512];
};

struct local ll[1024];

br_socket_t *socks[16384];

static dispatch_queue_t qg;

unsigned long long fib(unsigned long long n) {
    if (n < 2) {
        return n;
    }
    return fib(n -1) + fib(n - 2);
}


int on_message_complete(http_parser *parser) {
        br_client_t *c = parser->data;
        struct local *l = &ll[c->sock.fd];
        br_log_debug("message complete!");
        size_t buff_len = 1024*8;
        char *buff = malloc(buff_len);
        memset(buff, 0, buff_len);
        
        sprintf(buff, "HTTP/1.1 200 OK\r\n\r\nHola %20llu on %10d for %s %40llu\r\n", l->number, c->sock.fd, l->url, (unsigned long long)1);
        buff_len = strlen(buff);
        br_client_write(c, buff, buff_len, ^(br_client_t *c) {
            br_log_debug("CLIENT ERROR on write socket %d", c->sock.fd);
        });
        br_client_close(c);
    return 0;
}

int on_url(http_parser* parser, const char *at, size_t length) {
    br_client_t *c = parser->data;
    struct local *l = &ll[c->sock.fd];

    char tmpbuff[4096];
    snprintf(tmpbuff, sizeof(tmpbuff), "%s%.*s", l->url, (int)length, at);
    strncpy(l->url, tmpbuff, sizeof(l->url));
    return 0;
}

void run() {
    settings.on_message_complete = on_message_complete;
    settings.on_url = on_url;

    qg = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    
    br_log_info("CLIENT BUFFER SIZE: %ld", sizeof(ll));
    br_log_info("SOCKS         SIZE: %ld", sizeof(socks));
    
    br_loop_t *loop = br_loop_create();    

    br_log_info("%12p LOOP CREATED", loop);

    br_server_t *s = br_server_create(loop,
                                      "0.0.0.0",
                                      "9999",
                                      ^(br_client_t *c) 
    {   /* on_accept */
        count++;
        br_log_debug("CLIENT ON_ACCEPT number %d socket %d: %s:%s", count, c->sock.fd, c->sock.hbuf, c->sock.sbuf);
        
        if (c->sock.fd > sizeof(ll)) {
            br_client_close(c);
            return;
        }
        br_socket_addwatch((br_socket_t *)c, BRSOCKET_WATCH_READ);
        
        struct local *l = &ll[c->sock.fd];
        memset(l, 0, sizeof(struct local));
        http_parser *parser = &(l->parser);
        parser->data = c;
        l->number = count;
        c->udata = l;
        http_parser_init(parser, HTTP_REQUEST);
    }, ^(br_client_t *c, char *buff, size_t buff_len) {
        br_log_debug("CLIENT ON_READ socket %d bytes %d", c->sock.fd, (int)buff_len);
        struct local *l = &ll[c->sock.fd];
        http_parser *parser = &(l->parser);
        http_parser_execute(parser, &settings, buff, buff_len);
    }, ^(br_client_t *c) {
        br_log_debug("CLIENT ON_CLOSE %d", c->sock.fd);
        closed++;
    }, ^(br_server_t *s) {
        br_log_info("SERVER release: count %d closed %d %s", count, closed, (count == closed ? "OK" : "LEAKED"));
    });

    br_log_info("%12p SERVER CREATED", s);

    br_runloop(loop);
    
    br_log_info("DONE DONE DONE: count %d closed %d %s", count, closed, (count == closed ? "OK" : "LEAKED"));
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        run();
   }
    return 0;
}
