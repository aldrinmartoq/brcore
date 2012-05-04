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
        
//        dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
        dispatch_queue_t queue = dispatch_get_main_queue();
        
        fprintf(stderr, "HOLI\n");
        br_server_create("0.0.0.0", "9999", ^(br_client_t *c) {
//            NSLog(@"accepted client %d: %s:%s", c->fd, c->hbuf, c->sbuf);
            count++;
            if (count > 1000) {
                fprintf(stderr, "EXITING!\n");
                exit(0);
            }
        }, ^(br_client_t *c, char *buff, size_t buff_len) {
            dispatch_async(queue, ^{
//                NSLog(@"read: %d", (int)buff_len);
                size_t buff2_len = 1024*500;
                char *buff2 = malloc(buff2_len);
                memset(buff2, ' ', buff2_len);
                sprintf(buff2, "HTTP/1.1 200 OK\n\nHello %020llu on %010d\n", count, c->fd);
                buff2_len = strlen(buff2);
                br_client_write(c, buff2, buff2_len, ^(br_client_t *c) {
//                    NSLog(@"something wrong on write");
                });
                br_client_close(c);
            });
        }, ^(br_client_t *c) {
//            NSLog(@"closed client %d: %s:%s", c->fd, c->hbuf, c->sbuf);
        });
    }
    return 0;
}