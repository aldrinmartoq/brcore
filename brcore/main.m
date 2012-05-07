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

int on_message_complete(http_parser *parser) {
    br_client_t *c = parser->data;
    struct local *l = &ll[c->fd];
    br_log_debug("message complete!");
    size_t buff_len = 1024*10;
    char *buff = malloc(buff_len);
    memset(buff, 0, buff_len);

    sprintf(buff, "HTTP/1.1 200 OK\r\n\r\nHola %20llu on %10d for %s\r\n", l->number, c->fd, l->url);
    buff_len = strlen(buff);
    br_client_write(c, buff, buff_len, ^(br_client_t *c) {
        br_log_debug("CLIENT ERROR on write socket %d", c->fd);
    });
    br_client_close(c);

    return 0;
}

int on_url(http_parser* parser, const char *at, size_t length) {
    struct local *l = parser->data;
    
    char tmpbuff[4096];
    snprintf(tmpbuff, sizeof(tmpbuff), "%s%.*s", l->url, (int)length, at);
    strncpy(l->url, tmpbuff, sizeof(l->url));
    return 0;
}

void run() {
    settings.on_message_complete = on_message_complete;
    settings.on_url = on_url;

    br_log_info("CLIENT BUFFER SIZE: %ld\n", sizeof(ll));

    br_server_t *s = br_server_create("0.0.0.0", "9999", ^(br_client_t *c) {
        count++;
        br_log_debug("CLIENT ON_ACCEPT number %d socket %d: %s:%s", count, c->fd, c->hbuf, c->sbuf);
        
        if (c->fd > sizeof(ll)) {
            br_client_close(c);
            return;
        }
        
        struct local *l = &ll[c->fd];
        memset(l, 0, sizeof(struct local));
        http_parser *parser = &(l->parser);
        parser->data = c;
        l->number = count;
        c->udata = l;
        http_parser_init(parser, HTTP_REQUEST);
    }, ^(br_client_t *c, char *buff, size_t buff_len) {
        br_log_debug("CLIENT ON_READ socket %d bytes %d", c->fd, (int)buff_len);
        struct local *l = &ll[c->fd];
        http_parser *parser = &(l->parser);
        http_parser_execute(parser, &settings, buff, buff_len);

//        br_log_debug("CLIENT READ socket %d bytes %d", c->fd, (int)buff_len);
//        size_t buff2_len = 1024*500;
//        char *buff2 = malloc(buff2_len);
//        memset(buff2, ' ', buff2_len);
//        sprintf(buff2, "HTTP/1.1 200 OK\n\nHello %020llu on %010d\n", count, c->fd);
//        buff2_len = strlen(buff2);
//        br_client_write(c, buff2, buff2_len, ^(br_client_t *c) {
//            br_log_debug("CLIENT ERROR on write socket %d", c->fd);
//        });
//        br_log_debug("CLIENT WRITE %d", c->fd);
//        br_client_close(c);

    }, ^(br_client_t *c) {
        br_log_debug("CLIENT ON_CLOSE %d", c->fd);
        closed++;
    }, ^(br_server_t *s) {
        br_log_info("SERVER release: count %d closed %d %s", count, closed, (count == closed ? "OK" : "LEAKED"));
    });

    br_log_info("0x%llx Server created", s);

    br_runloop();
    
    br_log_info("DONE DONE DONE: count %d closed %d %s", count, closed, (count == closed ? "OK" : "LEAKED"));
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        run();
   }
    return 0;
}
