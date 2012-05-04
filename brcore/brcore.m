//
//  brcore.m
//  brcore
//
//  Created by Aldrin Martoq on 5/3/12.
//  Copyright (c) 2012 A0. All rights reserved.
//

#import "brcore.h"

struct br_write_request {
    char *buffer;
    size_t l, i;
};

static int _br_create_bind(char *hostname, char *servname) {
    struct addrinfo hints;
    struct addrinfo *result, *rp;
    int r, sfd;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;        /* IPv4 and IPv6 */
    hints.ai_socktype = SOCK_STREAM;    /* TCP */
    hints.ai_flags = AI_PASSIVE;        /* All interfaces */

    r = getaddrinfo(hostname, servname, &hints, &result);
    if (r != 0) {
        return -1;
    }

    for (rp = result; rp != NULL; rp = rp->ai_next) {
        sfd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (sfd == -1) {
            continue;
        }

        int yes = 1;
        r = setsockopt(sfd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
        if (r == -1) {
            perror("setsockopt");
            abort();
        }

        r = bind(sfd, rp->ai_addr, rp->ai_addrlen);
        if (r == 0) {
            /* bind success */
            break;
        }
        close(sfd);
    }

    if (rp == NULL) {
        perror("Could not bind");
        return -1;
    }

    freeaddrinfo(result);

    return sfd;
}

static int _br_nonblock(int sfd) {
    int flags, r;

    flags = fcntl(sfd, F_GETFD, 0);
    if (flags == -1) {
        perror("fcntl F_GETFD");
        return -1;
    }

    flags |= O_NONBLOCK | O_CLOEXEC;
    r = fcntl(sfd, F_SETFL, flags);
    if (r == -1) {
        perror("fcntl F_SETFL O_NONBLOCK");
        return -1;
    }
    
    return 0;
}

dispatch_queue_t _br_queue_write = NULL;


#ifndef __APPLE__
#define MAXEVENTS 128
static int efd = -1;
static struct epoll_event *events;

typedef void (_dispatch_main_q_handler_4LINUX)(void);
extern void _dispatch_main_queue_callback_4LINUX();
extern void _dispatch_register_signal_handler_4LINUX(_dispatch_main_q_handler_4LINUX);


void br_dispatch_handler() {
    _dispatch_main_queue_callback_4LINUX();
}

static int _br_server_socket_epoll_init() {
    if (efd != -1) {
        return efd;
    }
    events = calloc(MAXEVENTS, sizeof(struct epoll_event));
    if (events == NULL) {
        perror("malloc events");
        abort();
    }
    efd = epoll_create1(EPOLL_CLOEXEC);
    if (efd == -1) {
        perror("epoll_create");
        abort();
    }
    
    return efd;
}

static void _br_dispatch_init() {
    if (_br_queue_write == NULL) {
        _dispatch_register_signal_handler_4LINUX(br_dispatch_handler);
//        _br_queue_write = dispatch_queue_create("br_write_queue", 0);
        _br_queue_write = dispatch_get_main_queue();
        BRLog(@"    br queue: 0x%llX", (unsigned long long) _br_queue_write);
    }
}

static int _br_server_socket_epoll(char *hostname, char *servname, void (^on_accept)(br_client_t *), void (^on_read)(br_client_t *, char *, size_t), void (^on_close)(br_client_t *)) {
    int sfd, r;
    int client_num = 0;
    
    
    sfd = _br_create_bind(hostname, servname);
    if (sfd == -1) abort();
    r = _br_nonblock(sfd);
    
    r = listen(sfd, SOMAXCONN);
    if (r == -1) {
        perror("listen");
        abort();
    }
    
    _br_server_socket_epoll_init();
    _br_dispatch_init();

    struct epoll_event event;
    br_client_t server;
    server.fd = sfd;
    event.data.ptr = &server;
    event.events = EPOLLIN | EPOLLET;
    r = epoll_ctl(efd, EPOLL_CTL_ADD, sfd, &event);
    if (r == -1) {
        perror("epoll_ctl");
        abort();
    }
    while (true) {
        BRLog(@"%3d waiting on epoll", efd);
        int n = epoll_wait(efd, events, MAXEVENTS, -1);
        for (int i = 0; i < n; i++) {
            br_client_t *c = events[i].data.ptr;
            BRLog(@"%3d event on fd", c->fd);
            if ((events[i].events & EPOLLERR) || (events[i].events & EPOLLHUP) || (!(events[i].events & EPOLLIN))) {
                BRLog(@"%3d epoll error on fd: %s", c->fd, strerror(errno));
                close(c->fd);
                continue;
            } else if (sfd == c->fd) {
                BRLog(@"%3d accept on fd", c->fd);
                while (true) {
                    /* accept client */
                    struct sockaddr in_addr;
                    socklen_t in_len = sizeof(struct sockaddr);
                    int infd = accept(sfd, &in_addr, &in_len);
                    if (infd == -1) {
                        if ((errno == EAGAIN) || (errno == EWOULDBLOCK)) {
                            break;
                        }
                        BRLog(@"%3d unable to accept client: %s", c->fd, strerror(errno));
                        break;
                    }
                    r = _br_nonblock(infd);
                    if (r == -1) {
                        BRLog(@"%3d non block failed on fd", c->fd);
                        close(infd);
                        break;
                    }

                    /* create br_client_t */
                    BRLog(@"%3d creating client on fd", c->fd);
                    br_client_t *c = malloc(sizeof(br_client_t));
                    if (c == NULL) {
                        BRLog(@"%3d unable to alloc client memory: %s", c->fd, strerror(errno));
                        close(infd);
                        break;
                    }
                    memset(c, 0, sizeof(br_client_t));
                    c->fd = infd;
                    c->in_addr = in_addr;
                    r = getnameinfo(&in_addr, in_len, c->hbuf, sizeof(c->hbuf), c->sbuf, sizeof(c->sbuf), NI_NUMERICHOST | NI_NUMERICSERV);

                    /* setup epoll */
                    struct epoll_event event;
                    event.data.ptr = c;
                    event.events = EPOLLIN | EPOLLET;
                    r = epoll_ctl(efd, EPOLL_CTL_ADD, infd, &event);
                    if (r == -1) {
                        BRLog(@"%3d error on epoll_client: %s", c->fd, strerror(errno));
                        close(infd);
                        free(c);
                        break;
                    }
                    
                    /* call user block */
                    if (on_accept != NULL) {
                        on_accept(c);
                    }
                }
                continue;
            } else {
                while (true) {
                    BRLog(@"%3d read on fd", c->fd);
                    /* read data */
                    char buff[4096];
                    ssize_t count = read(c->fd, buff, sizeof(buff));
                    if (count == -1) {
                        if (errno != EAGAIN) {
                            br_client_close(c);
                        }
                        break;
                    } else if (count == 0) {
                        br_client_close(c);
                        break;
                    }
                    
                    /* call user block */
                    if (on_read != NULL) {
                        on_read(c, buff, count);
                    }
                }
                if (c->done) {
                    BRLog(@"%3d done on fd", c->fd);
                    /* call user block */
                    if (on_close != NULL) {
                        on_close(c);
                    }
                    free(c);
                }
            }
        }
    }
    free(events);
    close(sfd);
    
    return 0;
}
#endif

int br_server_create(char *hostname, char *servname, void (^on_accept)(br_client_t *), void (^on_read)(br_client_t *, char *, size_t), void (^on_close)(br_client_t *)){
    BRLog(@"creating server: %s %s", hostname, servname);
#ifndef __APPLE__
    return _br_server_socket_epoll(hostname, servname, on_accept, on_read, on_close);
#endif
    return 0;
}

void br_client_close(br_client_t *client) {
    BRLog(@"%3d br_client_close on fd", client->fd);
    if (client->done) return;
    dispatch_async(_br_queue_write, ^{
        close(client->fd);
        client->done = 1;
    });
}

void br_client_write(br_client_t *client, char *buff, size_t buff_len, void (^on_error)(br_client_t *)) {
    dispatch_async(_br_queue_write, ^{
        int r = write(client->fd, buff, buff_len);
        if (r == -1) {
            if (on_error == NULL) {
                BRLog(@"%3d AUTOCLOSING failed write on fd: %s", client->fd, strerror(errno));
                br_client_close(client);
            } else {
                on_error(client);
            }
        } else if (r < buff_len) {
            BRLog(@"%3d todo: add write request for %ld bytes", client->fd, (buff_len - r));
        }
    });
}
