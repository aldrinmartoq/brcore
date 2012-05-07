//
//  brcore-kqueue.m
//  brcore
//
//  Created by Aldrin Martoq on 5/6/12.
//  Copyright (c) 2012 A0. All rights reserved.
//

#import "brcore.h"
#import <sys/event.h>



////////////////////////////////
// PRIVATE AREA
////////////////////////////////

#define _BR_KQUEUE_MAX_EVENTS 128
#define _BR_KQUEUE_TIMEOUT 2
#define _BR_READ_BUFFLEN 1024*4

typedef struct br_server_list {
    br_server_t *s;
    struct br_server_list *next;
} br_server_list;

static void _br_create_bind_listen(br_server_t *s, char *hostname, char *servname);
static int _br_nonblock(int fd);
static void _br_init();
static void _br_server_addlist(br_server_t *s);
static void _br_server_closeall();

static dispatch_queue_t _br_loop_queue = NULL;
static dispatch_once_t _br_init_once;
static unsigned long long _br_runloop_usage = 0;
static br_server_list *_br_server_listhead = NULL;
static int kq = -1;


/* creates a server socket */
static void _br_create_bind_listen(br_server_t *s, char *hostname, char *servname) {
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
    
    r = listen(s->fd, SOMAXCONN);
    if (r == -1) {
        perror("listen");
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


/* internal setup */
static void _br_init() {
    /* libdispatch stuff */
    _br_loop_queue = dispatch_queue_create("br_loop_queue", 0);
    if (_br_loop_queue == NULL) {
        perror("dispatch queue create");
        abort();
    }

    /* sigterm handler */
    if (signal(SIGTERM, SIG_IGN) == SIG_ERR) {
        perror("ERROR unable no ignore SIGTERM");
        abort();
    }
    dispatch_source_t src_sigterm = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, _br_loop_queue);
    dispatch_source_set_event_handler(src_sigterm, ^{
        _br_server_closeall();
    });
    dispatch_resume(src_sigterm);
    br_log_trace("br_init");

    return;
}


/* append server to internal list */
static void _br_server_addlist(br_server_t *s) {
    br_server_list *n = malloc(sizeof(br_server_list));
    if (n == NULL) {
        perror("ERROR malloc br_server_list");
        abort();
    }
    memset(n, 0, sizeof(br_server_list));
    n->s = s;
    n->next = NULL;
    
    br_log_trace("added to serverlist: 0x%lx", n->s);
    if (_br_server_listhead == NULL) {
        _br_server_listhead = n;
        return;
    }
    br_server_list *item = _br_server_listhead;
    while (item->next != NULL) {
        item = item->next;
    }
    item->next = n;
}


/* close servers */
static void _br_server_closeall() {
    br_log_info("Closing servers");

    br_server_list *item_s = _br_server_listhead;
    while (item_s != NULL) {
        struct kevent ke;
        memset(&ke, 0, sizeof(struct kevent));
        EV_SET(&ke, item_s->s->fd, EVFILT_READ, EV_DELETE, 0, 5, item_s->s);
        int r = kevent(kq, &ke, 1, NULL, 0, NULL);
        if (r == -1) {
            perror("kevent");
            abort();
        }
        br_log_trace("%3d removed server from kq %d", item_s->s->fd, kq);

        /* call user block */
        void (^on_release)(br_server_t *) = (__bridge void (^)(br_server_t *x1))item_s->s->on_release;
        if (on_release != NULL) {
            on_release(item_s->s);
        }

        /* decrement runloop usage and continue */
        _br_runloop_usage--;
        item_s = item_s->next;
    }
}



////////////////////////////////
// PUBLIC API
////////////////////////////////


/* simple logging */
void br_log(char level, char *fmt, va_list ap) {
    char format[4096];
    snprintf(format, sizeof(format), "%5d %25s %c %s\n",
             getpid(),
             dispatch_queue_get_label(dispatch_get_current_queue()),
             level,
             fmt);
    vfprintf(stderr, format, ap);
}


/* trace log */
void br_log_trace(char *fmt, ...) {
#if BR_LOG_TRA_ENABLED
    va_list ap;
    va_start(ap, fmt);
    br_log('T', fmt, ap);
    va_end(ap);
#endif
}

/* debug log */
void br_log_debug(char *fmt, ...) {
#if BR_LOG_DEB_ENABLED
    va_list ap;
    va_start(ap, fmt);
    br_log('D', fmt, ap);
    va_end(ap);
#endif
}

/* info log */
void br_log_info(char *fmt, ...) {
#if BR_LOG_INF_ENABLED
    va_list ap;
    va_start(ap, fmt);
    br_log('I', fmt, ap);
    va_end(ap);
#endif
}

/* error log */
void br_log_error(char *fmt, ...) {
#if BR_LOG_ERR_ENABLED
    va_list ap;
    va_start(ap, fmt);
    br_log('E', fmt, ap);
    va_end(ap);
#endif
}


/* creates a server */
br_server_t *br_server_create(char *hostname,
                              char *servname,
                              void (^on_accept)(br_client_t *),
                              void (^on_read)(br_client_t *, char *, size_t),
                              void (^on_close)(br_client_t *),
                              void (^on_release)(br_server_t *)) {
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
    _br_create_bind_listen(s, hostname, servname);

    /* copy blocks references */
    s->on_release = (__bridge_retained void *) on_release;
    s->on_accept = (__bridge_retained void *) on_accept;
    s->on_close = (__bridge_retained void *) on_close;
    s->on_read = (__bridge_retained void *) on_read;

    /* add server to list and return */
    _br_server_addlist(s);

    br_log_trace("0x%lx server created", s);
    return s;
}


void br_client_close(br_client_t *c) {
    dispatch_sync(_br_loop_queue, ^{
        br_log_trace("%3d br_client_close 0x%lx done %d", c->fd, c, c->done);
        if (c->done) return;
        
        /* remove socket from kqueue */
        struct kevent ke;
        memset(&ke, 0, sizeof(struct kevent));
        EV_SET(&ke, c->fd, EVFILT_READ, EV_DELETE, 0, 0, c);
        int r = kevent(kq, &ke, 1, NULL, 0, NULL);
        if (r == -1) {
            br_log_trace("%3d %3d ERROR on kevent client: %s", c->fd, c->s->fd, strerror(errno));
            abort();
        }
        close(c->fd);
        c->done = 1;
        
        /* call user block */
        void (^on_close)(br_client_t *) = (__bridge void (^)(br_client_t *x))c->s->on_close;
        if (on_close != NULL) {
            on_close(c);
        }
        br_log_trace("%3d 0x%lx removing client", c->fd, c);
        
        //free(c);
        
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
            br_log_error("%3d TODO ADD WRITE REQUEST FOR %ld bytes", c->fd, (buff_len - r));
        }
        free(buff);
    });
}

/* runloop, it exists if everything is closed */
void br_runloop() {
    br_log_info("entering br_run_loop");

    /* kqueue init */
    struct kevent *kevents = NULL;
    
    kevents = calloc(_BR_KQUEUE_MAX_EVENTS, sizeof(struct kevent));
    if (kevents == NULL) {
        perror("ERROR calloc kevents");
        abort();
    }
    kq = kqueue();
    if (kq == -1) {
        perror("kqueue");
        abort();
    }
    
    /* add servers to kqueue */
    br_server_list *item_s = _br_server_listhead;
    while (item_s != NULL) {
        struct kevent ke;
        memset(&ke, 0, sizeof(struct kevent));
        EV_SET(&ke, item_s->s->fd, EVFILT_READ, EV_ADD, 0, 5, item_s->s);
        int r = kevent(kq, &ke, 1, NULL, 0, NULL);
        if (r == -1) {
            perror("kevent");
            abort();
        }
        br_log_trace("%3d added server to kq %d", item_s->s->fd, kq);

        /* increment runloop usage and continue */
        _br_runloop_usage++;        
        item_s = item_s->next;
    }
    
    while (_br_runloop_usage > 0) {
        br_log_trace("%3d kevent, usage: %llu", kq, _br_runloop_usage);
        struct timespec kqtimeout;
        kqtimeout.tv_sec = _BR_KQUEUE_TIMEOUT;
        kqtimeout.tv_nsec = 0;
        memset(kevents, 0, _BR_KQUEUE_MAX_EVENTS * sizeof(struct kevent));
        int n = kevent(kq, NULL, 0, kevents, _BR_KQUEUE_MAX_EVENTS, &kqtimeout);

        // TODO: if (n == -1)

        for (int i = 0; i < n; i++) {
            br_client_t *t = kevents[i].udata;
            br_log_trace("%3d event on socket %s flags 0x%04x 0x%04x data %d", t->fd, (t->type ? "CLIENT" : "SERVER"), kevents[i].flags, kevents[i].fflags, kevents[i].data);

            // TODO if error on socket

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

                    /* add socket to kqueue */
                    struct kevent ke;
                    memset(&ke, 0, sizeof(struct kevent));
                    EV_SET(&ke, c->fd, EVFILT_READ, EV_ADD, 0, 0, c);
                    r = kevent(kq, &ke, 1, NULL, 0, NULL);
                    if (r == -1) {
                        br_log_trace("%3d %3d ERROR on kevent client: %s", fd, s->fd, strerror(errno));
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
                    //char buff[_BR_READ_BUFFLEN];
                    ssize_t count = read(c->fd, c->rbuff, sizeof(c->rbuff));
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
                        on_read(c, c->rbuff, count);
                    }
                }
                if (c->done) {
                    free(c);
                }
                continue;
            } /* read from client */
        } /* for */
    } /* while */
}
