/*
 * LD_PRELOAD para srcds: bloquea la conexión IPC al cliente de Steam abierto (127.0.0.1:57343).
 * Sin esto Steam toma al servidor dedicado por L4D2 en ejecución, se queda en "Stopping"
 * y no deja abrir el juego. Sin libc de 32 bits: se compila con -nostdlib y resuelve en runtime.
 */
struct sockaddr_in4 { unsigned short family; unsigned short port; unsigned int addr; char zero[8]; };

typedef int (*connect_fn)(int, const void *, unsigned int);
extern void *dlsym(void *, const char *);
extern int *__errno_location(void);

#define RTLD_NEXT ((void *)-1l)
#define STEAM_IPC_PORT 0xFFDF  /* htons(57343) */
#define LOOPBACK 0x0100007Fu   /* 127.0.0.1 en orden de red */

int connect(int fd, const void *addr, unsigned int len)
{
    static connect_fn real;
    const struct sockaddr_in4 *in = addr;

    if (in && len >= sizeof(*in) && in->family == 2 && in->port == STEAM_IPC_PORT && in->addr == LOOPBACK) {
        *__errno_location() = 111; /* ECONNREFUSED */
        return -1;
    }
    if (!real)
        real = (connect_fn)dlsym(RTLD_NEXT, "connect");
    return real(fd, addr, len);
}
