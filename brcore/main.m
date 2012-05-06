//
//  main.m
//  brcore
//
//  Created by Aldrin Martoq on 5/3/12.
//  Copyright (c) 2012 A0. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "brcore.h"

void run() {
    __block unsigned long long count = 0;
    
    br_server_t *s = br_server_create("0.0.0.0", "9999", ^(br_client_t *c) {
        count++;
        br_log_debug("ACCEPT CLIENT number %d socket %d: %s:%s", count, c->fd, c->hbuf, c->sbuf);
    }, ^(br_client_t *c, char *buff, size_t buff_len) {
        br_log_debug("CLIENT READ socket %d bytes %d", c->fd, (int)buff_len);
        size_t buff2_len = 1024*500;
        char *buff2 = malloc(buff2_len);
        memset(buff2, ' ', buff2_len);
        sprintf(buff2, "HTTP/1.1 200 OK\n\nHello %020llu on %010d\n", count, c->fd);
        buff2_len = strlen(buff2);
        br_client_write(c, buff2, buff2_len, ^(br_client_t *c) {
            br_log_debug("CLIENT ERROR on write socket %d", c->fd);
        });
        br_log_debug("CLIENT WRITE %d", c->fd);
        br_client_close(c);
    }, ^(br_client_t *c) {
        br_log_debug("CLIENT CLOSED %d", c->fd);
    });
    
    br_log_info("0x%llx Server created", s);
    
    br_runloop();
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        run();
   }
    return 0;
}
