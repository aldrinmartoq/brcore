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
        br_server_create("0.0.0.0", "9999", ^(br_client_t *c) {
            NSLog(@"accepted: %s", c->hbuf);
        }, ^(br_client_t *c) {
            NSLog(@"read: 0x%llX", (unsigned long long)c);
        });
    }
    return 0;
}

