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

static void _br_create_bind_listen(br_server_t *s, char *hostname, char *servname);
static int _br_nonblock(int fd);
static void _br_init();
static void _br_loop_sock_add(br_loop_t *loop, br_socket_t *sock);
static void _br_server_closeall();

static dispatch_queue_t _br_loop_queue = NULL;
static dispatch_once_t _br_init_once;
static br_loop_t *_br_loop_list = NULL; // FIXME: support multiple loops


/* creates a server socket */
static void _br_create_bind_listen(br_server_t *s, char *hostname, char *servname) {
    struct addrinfo hints;
    struct addrinfo *result, *rp;
    int r;
    
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;        /* IPv4 and IPv6 */
    hints.ai_socktype = SOCK_STREAM;    /* TCP */
    hints.ai_flags = AI_PASSIVE;        /* All interfaces */
    
    memcpy(s->sock.hbuf, hostname, sizeof(s->sock.hbuf));
    memcpy(s->sock.sbuf, servname, sizeof(s->sock.sbuf));
    s->sock.type = BRSOCKET_SERVER;
    
    r = getaddrinfo(hostname, servname, &hints, &result);
    if (r != 0) {
        perror("getaddrinfo");
        abort();
    }
    
    for (rp = result; rp != NULL; rp = rp->ai_next) {
        s->sock.fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (s->sock.fd == -1) {
            continue;
        }
        
        int yes = 1;
        r = setsockopt(s->sock.fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
        if (r == -1) {
            perror("setsockopt");
            abort();
        }
        
        r = bind(s->sock.fd, rp->ai_addr, rp->ai_addrlen);
        if (r == 0) {
            /* bind success */
            s->sock.in_addr = *(rp->ai_addr);
            break;
        }
        close(s->sock.fd);
    }
    
    if (rp == NULL) {
        perror("Could not bind");
        abort();
    }
    
    freeaddrinfo(result);
    
    r = _br_nonblock(s->sock.fd);
    if (r == -1) {
        perror("non blocking IO");
        abort();
    }
    
    r = listen(s->sock.fd, SOMAXCONN);
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
    
    flags |= O_NONBLOCK;
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
    
    if (signal(SIGINT, SIG_IGN) == SIG_ERR) {
        perror("ERROR unable no ignore SIGINT");
        abort();
    }
    dispatch_source_t src_sigint = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, _br_loop_queue);
    dispatch_source_set_event_handler(src_sigint, ^{
        _br_server_closeall();
    });
    dispatch_resume(src_sigint);

    
    br_log_trace("_br_init");

    return;
}


/* dump loop sockets */
static void _br_loop_sock_dump(br_loop_t *loop) {
    br_log_trace("%12p br_loop usage %d sockets: %d", loop, loop->usage, loop->sockets_len);
    for (int i = 0; i < loop->sockets_len; i++) {
        br_socket_t *sock = loop->sockets[i];
        br_log_trace("%12p br_loop usage %d %s socket %d usage %u %12p", loop, loop->usage, (sock->type == BRSOCKET_SERVER ? "SERVER" : "CLIENT"), sock->fd, sock->usage, sock);
    }
}

/* add socket to loop */
static void _br_loop_sock_add(br_loop_t *loop, br_socket_t *sock) {
    br_log_trace("%12p add socket %d to loop", loop, sock->fd);
    
    if (loop->sockets_len >= BRLOOP_SCK_ARR_LEN) {
        br_log_error("SOCKET LEAKED: TODO FIXME!");
        return; /* ignoring */
    }
    sock->loop = loop;

    loop->sockets[loop->sockets_len] = sock;
    loop->sockets_len++;
    loop->usage++;
}

/* del socket from loop */
static void _br_loop_sock_del(br_loop_t *loop, br_socket_t *sock) {
    for (int i = 0; i < loop->sockets_len; i++) {
        if (sock == loop->sockets[i]) {
            br_log_trace("%12p del socket %d from loop %12p", loop, sock->fd, sock);
            loop->sockets_len--;
            loop->usage--;
            loop->sockets[i] = loop->sockets[loop->sockets_len];
            return;
        }
    }
    br_log_error("SOCKET NOT FOUND: %12p", sock);
}

/* release all server socket on all loops */
static void _br_server_closeall() {
    
    // TODO: support multiple loops
    
    br_log_info("_br_loop_all_release_servers");
    if (_br_loop_list == NULL) {
        br_log_info("_br_loop_all_release_servers NO LOOPS");
        return;
    }
    
    br_loop_t *loop = _br_loop_list;

    for (int i = 0; i < loop->sockets_len; i++) {
        br_socket_t *sock = loop->sockets[i];
        if (sock->type == BRSOCKET_SERVER) {
            br_socket_delwatch(sock, BRSOCKET_WATCH_READ);
            close(sock->fd);
            _br_loop_sock_del(loop, sock);
            // TODO: we don't free server sockets
            // sock->usage--;
        }
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


/* creates a loop */
br_loop_t *br_loop_create() {
    /* init internal stuff */
    dispatch_once(&_br_init_once, ^{ _br_init(); });
    
    /* create loop */
    br_loop_t *loop = malloc(sizeof(br_loop_t));
    if (loop == NULL) {
        perror("br_loop_create: malloc");
        abort();
    }

    br_log_trace("%12p br_loop_create", loop);
    memset(loop, 0, sizeof(br_loop_t));

    /* kqueue init */
    loop->qfd = kqueue();
    if (loop->qfd == -1) {
        perror("kqueue");
        abort();
    }

    /* add to loop list and return */
    _br_loop_list = loop;
    br_log_trace("%12p br_loop_create done: qfd %d", loop, loop->qfd);

    return loop;
}


/* creates a server */
br_server_t *br_server_create(br_loop_t *loop,
                              char *hostname,
                              char *servname,
                              void (^on_accept)(br_client_t *),
                              void (^on_read)(br_client_t *, char *, size_t),
                              void (^on_close)(br_client_t *),
                              void (^on_release)(br_server_t *)) {
    /* create server */
    br_server_t *s = malloc(sizeof(br_server_t));
    if (s == NULL) {
        perror("Failed to allocate br_server_t");
        abort();
    }
    memset(s, 0, sizeof(br_server_t));
    s->sock.usage = 1;

    /* setup socket */
    _br_create_bind_listen(s, hostname, servname);

    /* copy blocks references */
    s->on_release = (__bridge_retained void *) on_release;
    s->on_accept = (__bridge_retained void *) on_accept;
    s->on_close = (__bridge_retained void *) on_close;
    s->on_read = (__bridge_retained void *) on_read;

    /* add server to loop and return */
    _br_loop_sock_add(loop, (br_socket_t *)s);

    br_log_trace("%12p server created", s);
    return s;
}


/* add socket to watch queue */
void br_socket_addwatch(br_socket_t *s, int mode) {
    struct kevent ke;
    memset(&ke, 0, sizeof(struct kevent));

    if (mode == BRSOCKET_WATCH_READ) {
        EV_SET(&ke, s->fd, EVFILT_READ, EV_ADD, 0, 0, s);
        br_log_trace("%3d %3d add watch read", s->loop->qfd, s->fd);
    } else if (mode == BRSOCKET_WATCH_WRITE) {
        EV_SET(&ke, s->fd, EVFILT_WRITE, EV_ADD, 0, 0, s);
        br_log_trace("%3d %3d add watch write", s->loop->qfd, s->fd);
    } else if (mode == BRSOCKET_WATCH_READWRITE) {
        EV_SET(&ke, s->fd, EVFILT_READ | EVFILT_WRITE, EV_ADD, 0, 0, s);
        br_log_trace("%3d %3d add watch read/write", s->loop->qfd, s->fd);
    }
    int r = kevent(s->loop->qfd, &ke, 1, NULL, 0, NULL);
    if (r == -1) {
        perror("kevent");
        abort();
    }
}


void br_socket_delwatch(br_socket_t *s, int mode) {
    struct kevent ke;
    memset(&ke, 0, sizeof(struct kevent));
    
    if (mode == BRSOCKET_WATCH_READ) {
        EV_SET(&ke, s->fd, EVFILT_READ, EV_DELETE, 0, 0, s);
        br_log_trace("%3d %3d del watch read", s->loop->qfd, s->fd);
    } else if (mode == BRSOCKET_WATCH_WRITE) {
        EV_SET(&ke, s->fd, EVFILT_WRITE, EV_DELETE, 0, 0, s);
        br_log_trace("%3d %3d del watch write", s->loop->qfd, s->fd);
    } else if (mode == BRSOCKET_WATCH_READWRITE) {
        EV_SET(&ke, s->fd, EVFILT_READ | EVFILT_WRITE, EV_DELETE, 0, 0, s);
        br_log_trace("%3d %3d del watch read/write", s->loop->qfd, s->fd);
    }
    int r = kevent(s->loop->qfd, &ke, 1, NULL, 0, NULL);
    if (r == -1) {
        perror("kevent");
        abort();
    }    
}


void br_client_close(br_client_t *c) {
    dispatch_sync(_br_loop_queue, ^{
        br_log_trace("%3d br_client_close %12p usage %u", c->sock.fd, c, c->sock.usage);

        /* decrement usage and test if ready to close */
        if (c->sock.usage == 0) return;
        c->sock.usage--;
    });
}


void br_client_write(br_client_t *c, char *buff, size_t buff_len, void (^on_error)(br_client_t *)) {
    dispatch_sync(_br_loop_queue, ^{
        br_log_trace("%3d br_client_write %12p", c->sock.fd, c);
        int r = write(c->sock.fd, buff, buff_len);
        if (r == -1) {
            if (on_error == NULL) {
                br_log_trace("%3d ERROR write on fd: %s", c->sock.fd, strerror(errno));
                br_client_close(c);
            } else {
                on_error(c);
            }
        } else if (r < buff_len) {
            br_log_error("%3d TODO ADD WRITE REQUEST FOR %ld bytes", c->sock.fd, (buff_len - r));
        }
        free(buff);
    });
}

/* runloop, it exists if everything is closed */
void br_runloop(br_loop_t *loop) {
    br_log_info("%12p br_run_loop", loop);
    
    /* kqueue init */
    struct kevent *kevents = NULL;
    kevents = calloc(_BR_KQUEUE_MAX_EVENTS, sizeof(struct kevent));
    if (kevents == NULL) {
        perror("ERROR calloc kevents");
        abort();
    }

    br_log_trace("%3d kevent, usage: %llu", loop->qfd, loop->usage);

    /* add servers to kqueue */
    for (int i = 0; i < loop->sockets_len; i++) {
        br_socket_t *sock = loop->sockets[i];
        if (sock->type == BRSOCKET_SERVER) {
            br_socket_addwatch(sock, BRSOCKET_WATCH_READ);
        }
    }

    while (loop->usage > 0) {
        br_log_trace("%3d kevent, usage: %llu", loop->qfd, loop->usage);
        struct timespec kqtimeout;
        kqtimeout.tv_sec = _BR_KQUEUE_TIMEOUT;
        kqtimeout.tv_nsec = 0;
        memset(kevents, 0, _BR_KQUEUE_MAX_EVENTS * sizeof(struct kevent));
        int n = kevent(loop->qfd, NULL, 0, kevents, 1, &kqtimeout);

        // TODO: if (n == -1)
        if (n == 0) {
            br_log_info("usage: %u", loop->usage);
        }

        for (int i = 0; i < n; i++) {
            br_socket_t *sock = kevents[i].udata;
            br_log_trace("%3d event %d on socket %s usage %d filter 0x%4x flags 0x%4x fflags 0x%4x data %d", sock->fd, i, (sock->type ? "CLIENT" : "SERVER"), sock->usage, kevents[i].filter, kevents[i].flags, kevents[i].fflags, kevents[i].data);

            // TODO if error on socket

            /* new client on server */
            if (sock->type == BRSOCKET_SERVER) {
                br_server_t *s = (br_server_t *)sock;
                /* accept clients */
                while (true) {
                    int r;
                    struct sockaddr in_addr;
                    socklen_t in_len = sizeof(struct sockaddr);
                    int fd = accept(s->sock.fd, &in_addr, &in_len);
                    if (fd == -1) {
                        if ((errno == EAGAIN) || (errno == EWOULDBLOCK)) {
                            br_log_trace("%3d server EGAIN | EWOULDBLOCK", s->sock.fd);
                            break;
                        }
                        br_log_trace("%3d ERROR accept client: %s", s->sock.fd, strerror(errno));
                        break;
                    }
                    r = _br_nonblock(fd);
                    if (r == -1) {
                        br_log_trace("%3d %3d ERROR nonblocking", fd, s->sock.fd);
                        close(fd);
                        break;
                    }

                    /* create client */
                    br_client_t *c = malloc(sizeof(br_client_t));
                    if (c == NULL) {
                        br_log_trace("%3d %3d ERROR malloc client: %s", fd, s->sock.fd, strerror(errno));
                        close(fd);
                        break;
                    }

                    br_log_trace("%3d %12p client created server %d", fd, c, s->sock.fd);
                    memset(c, 0, sizeof(br_client_t));
                    c->sock.fd = fd;
                    c->sock.type = BRSOCKET_CLIENT;
                    c->sock.in_addr = in_addr;
                    c->sock.usage = 1;
                    c->serv = s;
                    r = getnameinfo(&in_addr, in_len, c->sock.hbuf, sizeof(c->sock.hbuf), c->sock.sbuf, sizeof(c->sock.sbuf), NI_NUMERICHOST | NI_NUMERICSERV);

                    /* add socket to loop */
                    _br_loop_sock_add(loop, (br_socket_t *)c);

                    /* call user block */
                    void (^on_accept)(br_client_t *) = (__bridge void (^)(br_client_t *x))s->on_accept;
                    if (on_accept != NULL) {
                        on_accept(c);
                    }
                } /* accept clients */
                continue;
            } /* new client from server */
            /* read from client */
            if (sock->type == BRSOCKET_CLIENT) {
                br_client_t *c = (br_client_t *)sock;
                while (true) {
                    /* read from socket */
                    ssize_t count = read(c->sock.fd, c->rbuff, sizeof(c->rbuff));
                    if (count == -1) {
                        if (errno != EAGAIN) {
                            br_log_trace("%3d ERROR read client: %s", c->sock.fd, strerror(errno));
                            br_client_close(c);
                        }
                        br_log_trace("%3d %12p read fd EGAIN", c->sock.fd, c);
                        break;
                    } else if (count == 0) {
                        br_client_close(c);
                        break;
                    }
                    br_log_trace("%3d %12p read on fd count:%ld", c->sock.fd, c, count);
                    
                    /* call user block */
                    void (^on_read)(br_client_t *, char *, size_t) = (__bridge void (^)(br_client_t *x1, char *x2, size_t x3))c->serv->on_read;
                    if (on_read != NULL) {
                        on_read(c, c->rbuff, count);
                    }
                }
                continue;
            } /* read from client */
        } /* for */
        
        /* free unused sockets */
        dispatch_sync(_br_loop_queue, ^{
            _br_loop_sock_dump(loop);
            for (int i = 0; i < loop->sockets_len; ) {
                br_socket_t *sock = loop->sockets[i];
                if (sock->type == BRSOCKET_CLIENT && sock->usage == 0) {
                    br_client_t *c = (br_client_t *)sock;
                    
                    /* remove socket watchers */
                    br_socket_delwatch(sock, BRSOCKET_WATCH_READ);
                    
                    close(sock->fd);
                    
                    /* call user block */
                    void (^on_close)(br_client_t *) = (__bridge void (^)(br_client_t *x))c->serv->on_close;
                    if (on_close != NULL) {
                        on_close(c);
                    }
                    br_log_trace("%3d %12p removed client", c->sock.fd, c);
                    
                    _br_loop_sock_del(loop, sock);
                    free(sock);
                } else {
                    i++;
                }
            }
        });
    } /* while */
}
