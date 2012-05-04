//
//  main.m
//  brcore
//
//  Created by Aldrin Martoq on 5/3/12.
//  Copyright (c) 2012 A0. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "brcore.h"

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        __block unsigned long long count = 0;
        
        br_server_create("0.0.0.0", "9999", ^(br_client_t *c) {
            //NSLog(@"accepted client %d: %s:%s", c->fd, c->hbuf, c->sbuf);
            count++;
        }, ^(br_client_t *c, char *buff, size_t buff_len) {
            //NSLog(@"read: %*s", (int)buff_len, buff);
            
            char buff2[1024*1];
            memset(buff2, ' ', sizeof(buff2));
            sprintf(buff2, "HTTP/1.1 200 OK\n\nHello %020llu on %010d\n", count, c->fd);
            size_t buff2_len = strlen(buff2);
            
            br_client_write(c, buff2, buff2_len, ^(br_client_t *c) {
                //NSLog(@"something wrong on write");
            });
            
            br_client_close(c);
        }, ^(br_client_t *c) {
            //NSLog(@"closed client %d: %s:%s", c->fd, c->hbuf, c->sbuf);
        });
    }
    return 0;
}

