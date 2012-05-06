//
//  brcore-linux.m
//  brcore
//
//  Created by Aldrin Martoq on 5/4/12.
//  Copyright (c) 2012 A0. All rights reserved.
//

#import "brcore.h"
#import <sys/epoll.h>
#import <pthread.h>



////////////////////////////////
// PRIVATE AREA
////////////////////////////////

static void _br_create_bind(br_server_t *s, char *hostname, char *servname);
static int _br_nonblock(int fd);
static void _br_dispatch_handler();
static void _br_init();

#define _BR_EPOLL_MAX_EVENTS 128
#define _BR_EPOLL_TIMEOUT 1000
#define _BR_READ_BUFFLEN 1024*4
static int _br_epoll_fd = -1;
static struct epoll_event *_br_epoll_events = NULL;
static dispatch_queue_t _br_loop_queue = NULL;
typedef void (_dispatch_main_q_handler_4LINUX)(void);
extern void _dispatch_main_queue_callback_4LINUX();
extern void _dispatch_register_signal_handler_4LINUX(_dispatch_main_q_handler_4LINUX);
static dispatch_once_t _br_init_once;
static unsigned long long _br_runloop_usage = 0;


/* creates a server socket */
static void _br_create_bind(br_server_t *s, char *hostname, char *servname) {
    struct addrinfo hints;
    struct addrinfo *result, *rp;
    int r;
    
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;        /* IPv4 and IPv6 */
    hints.ai_socktype = SOCK_STREAM;    /* TCP */
    hints.ai_flags = AI_PASSIVE;        /* All interfaces */
    
    memcpy(s->hbuf, hostname, sizeof(s->hbuf));
    memcpy(s->sbuf, servname, sizeof(s->sbuf));
    s->type = BRSOCKET_SERVER;
    
    r = getaddrinfo(hostname, servname, &hints, &result);
    if (r != 0) {
        perror("getaddrinfo");
        abort();
    }
    
    for (rp = result; rp != NULL; rp = rp->ai_next) {
        s->fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (s->fd == -1) {
            continue;
        }
        
        int yes = 1;
        r = setsockopt(s->fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
        if (r == -1) {
            perror("setsockopt");
            abort();
        }
        
        r = bind(s->fd, rp->ai_addr, rp->ai_addrlen);
        if (r == 0) {
            /* bind success */
            s->in_addr = *(rp->ai_addr);
            break;
        }
        close(s->fd);
    }

    if (rp == NULL) {
        perror("Could not bind");
        abort();
    }

    freeaddrinfo(result);

    r = _br_nonblock(s->fd);
    if (r == -1) {
        perror("non blocking IO");
        abort();
    }
}


/* configure socket for non-blocking I/O */
static int _br_nonblock(int fd) {
    int flags, r;
    
    flags = fcntl(fd, F_GETFD, 0);
    if (flags == -1) {
        perror("fcntl F_GETFD");
        return -1;
    }
    
    flags |= O_NONBLOCK | O_CLOEXEC;
    r = fcntl(fd, F_SETFL, flags);
    if (r == -1) {
        perror("fcntl F_SETFL O_NONBLOCK O_CLOEXEC");
        return -1;
    }

    return 0;
}


/* libdispatch hack */
static void _br_dispatch_handler() {
    _dispatch_main_queue_callback_4LINUX();
}


/* internal setup */
static void _br_init() {
    /* epoll stuff */
    _br_epoll_events = calloc(_BR_EPOLL_MAX_EVENTS, sizeof(struct epoll_event));
    if (_br_epoll_events == NULL) {
        perror("Failed to allocate _br_epoll_events");
        abort();
    }
    _br_epoll_fd = epoll_create1(EPOLL_CLOEXEC);
    if (_br_epoll_fd == -1) {
        perror("epoll_create1");
        abort();
    }
    
    /* libdispatch stuff */
    _br_loop_queue = dispatch_queue_create("br_loop_queue", 0);
    if (_br_loop_queue == NULL) {
        perror("dispatch queue create");
        abort();
    }
    _dispatch_register_signal_handler_4LINUX(_br_dispatch_handler);
    
    return;
}



////////////////////////////////
// PUBLIC API
////////////////////////////////


/* simple logging */
void br_log(char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    char format[4096];
    snprintf(format, sizeof(format), "%5d %25s %s\n",
            getpid(),
            dispatch_queue_get_label(dispatch_get_current_queue()),
            fmt);
    vfprintf(stderr, format, ap);
    va_end(ap);
}


/* creates a server */
br_server_t *br_server_create(char *hostname,
                              char *servname,
                              void (^on_accept)(br_client_t *),
                              void (^on_read)(br_client_t *, char *, size_t),
                              void (^on_close)(br_client_t *)) {
    int r;

    /* init internal stuff */
    dispatch_once(&_br_init_once, ^{ _br_init(); });

    /* create server */
    br_server_t *s = malloc(sizeof(br_server_t));
    if (s == NULL) {
        perror("Failed to allocate br_server_t");
        abort();
    }
    memset(s, 0, sizeof(br_server_t));
    
    /* setup socket */
    _br_create_bind(s, hostname, servname);
    r = listen(s->fd, SOMAXCONN);
    if (r == -1) {
        perror("listen");
        abort();
    }

    /* add socket to epoll */
    struct epoll_event event;
    event.data.ptr = s;
    event.events = EPOLLIN | EPOLLET;
    r = epoll_ctl(_br_epoll_fd, EPOLL_CTL_ADD, s->fd, &event);
    if (r == -1) {
        perror("epoll_ctl");
        abort();
    }
    
    /* copy blocks references */
    s->on_accept = (__bridge_retained void *) on_accept;
    s->on_close = (__bridge_retained void *) on_close;
    s->on_read = (__bridge_retained void *) on_read;

    /* increment runloop usage and return */
    _br_runloop_usage++;

    br_log_trace("server created 0x%lx", s);
    return s;
}

void br_client_close(br_client_t *c) {
    dispatch_sync(_br_loop_queue, ^{
        br_log_trace("%3d br_client_close 0x%lx done %d", c->fd, c, c->done);
        if (c->done) return;
        close(c->fd);
        c->done = 1;
        
        /* call user block */
        void (^on_close)(br_client_t *) = (__bridge void (^)(br_client_t *x))c->s->on_close;
        if (on_close != NULL) {
            on_close(c);
        }
        br_log_trace("%3d 0x%lx removing client", c->fd, c);
        
        free(c);
        
        /* decrement loop usage */
        _br_runloop_usage--;
    });
}

void br_client_write(br_client_t *c, char *buff, size_t buff_len, void (^on_error)(br_client_t *)) {
    dispatch_sync(_br_loop_queue, ^{
        br_log_trace("%3d br_client_write 0x%lx", c->fd, c);
        int r = write(c->fd, buff, buff_len);
        if (r == -1) {
            if (on_error == NULL) {
                br_log_trace("%3d ERROR write on fd: %s", c->fd, strerror(errno));
                br_client_close(c);
            } else {
                on_error(c);
            }
        } else if (r < buff_len) {
            br_log_trace("%3d TODO ADD WRITE REQUEST FOR %ld bytes", c->fd, (buff_len - r));
        }
        free(buff);
    });
}

/* runloop, it exists if everything is closed */
void br_runloop() {
    br_log_trace("entering runloop");
    
    int maxfd = 0;
    
    while (_br_runloop_usage > 0) {
        br_log_trace("%3d epoll_wait, usage: %llu", _br_epoll_fd, _br_runloop_usage);
        int n = epoll_wait(_br_epoll_fd, _br_epoll_events, _BR_EPOLL_MAX_EVENTS, _BR_EPOLL_TIMEOUT);
        _br_dispatch_handler();
        for (int i = 0; i < n; i++) {
            br_client_t *t = _br_epoll_events[i].data.ptr;
            br_log_trace("%3d event on socket %s flags 0x%04x", t->fd, (t->type ? "CLIENT" : "SERVER"), _br_epoll_events[i].events);
            if ((_br_epoll_events[i].events & EPOLLERR) || (_br_epoll_events[i].events & EPOLLHUP) || (!(_br_epoll_events[i].events & EPOLLIN))) {
                br_log_trace("%3d ERROR epoll on fd: %s", t->fd, strerror(errno));
                if (t->type == BRSOCKET_CLIENT) {
                    br_client_close(t);
                }
                continue;
            }

            /* new client on server */
            if (t->type == BRSOCKET_SERVER) {
                br_server_t *s = (br_server_t *)t;
                /* accept clients */
                while (true) {
                    int r;
                    struct sockaddr in_addr;
                    socklen_t in_len = sizeof(struct sockaddr);
                    int fd = accept(s->fd, &in_addr, &in_len);
                    if (fd == -1) {
                        if ((errno == EAGAIN) || (errno == EWOULDBLOCK)) {
                            br_log_trace("%3d server EGAIN | EWOULDBLOCK", s->fd);
                            break;
                        }
                        br_log_trace("%3d ERROR accept client: %s", s->fd, strerror(errno));
                        break;
                    }
                    r = _br_nonblock(fd);
                    if (r == -1) {
                        br_log_trace("%3d %3d ERROR nonblocking", fd, s->fd);
                        close(fd);
                        break;
                    }
                    
                    /* create client */
                    br_client_t *c = malloc(sizeof(br_client_t));
                    if (c == NULL) {
                        br_log_trace("%3d %3d ERROR malloc client: %s", fd, s->fd, strerror(errno));
                        close(fd);
                        break;
                    }
                    
                    br_log_trace("%3d 0x%lx client created server %d", fd, c, s->fd);
                    memset(c, 0, sizeof(br_client_t));
                    c->fd = fd;
                    c->type = BRSOCKET_CLIENT;
                    c->in_addr = in_addr;
                    c->s = s;
                    r = getnameinfo(&in_addr, in_len, c->hbuf, sizeof(c->hbuf), c->sbuf, sizeof(c->sbuf), NI_NUMERICHOST | NI_NUMERICSERV);
                    
                    /* increment loop usage */
                    _br_runloop_usage++;
                    
                    
                    /* add socket to epoll */
                    struct epoll_event event;
                    event.data.ptr = c;
                    event.events = EPOLLIN | EPOLLET;
                    r = epoll_ctl(_br_epoll_fd, EPOLL_CTL_ADD, fd, &event);
                    if (r == -1) {
                        br_log_trace("%3d %3d ERROR on epoll_client: %s", fd, s->fd, strerror(errno));
                        br_client_close(c);
                        continue;
                    }
                    
                    /* call user block */
                    void (^on_accept)(br_client_t *) = (__bridge void (^)(br_client_t *x))s->on_accept;
                    if (on_accept != NULL) {
                        on_accept(c);
                    }
                } /* accept clients */
                continue;
            } /* new client from server */
            /* read from client */
            if (t->type == BRSOCKET_CLIENT) {
                br_client_t *c = (br_client_t *)t;
                while (true) {
                    /* read from socket */
                    char buff[_BR_READ_BUFFLEN];
                    ssize_t count = read(c->fd, buff, sizeof(buff));
                    if (count == -1) {
                        if (errno != EAGAIN) {
                            br_log_trace("%3d ERROR read client: %s", c->fd, strerror(errno));
                            br_client_close(c);
                        }
                        br_log_trace("%3d 0x%lx read fd EGAIN", c->fd, c);
                        break;
                    } else if (count == 0) {
                        br_client_close(c);
                        break;
                    }
                    br_log_trace("%3d 0x%lx read on fd count:%ld", c->fd, c, count);
                    
                    /* call user block */
                    void (^on_read)(br_client_t *, char *, size_t) = (__bridge void (^)(br_client_t *x1, char *x2, size_t x3))c->s->on_read;
                    if (on_read != NULL) {
                        on_read(c, buff, count);
                    }
                }
                continue;
            } /* read from client */
        } /* for */
    } /* while */
}
