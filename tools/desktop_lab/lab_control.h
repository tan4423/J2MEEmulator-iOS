/* Opt-in, same-user local research control. No shell, network listener,
 * desktop input, credentials or arbitrary file paths. Main SDL thread only. */
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
static int ctl_fd=-1,ctl_dir=-1;
static char ctl_path[sizeof(((struct sockaddr_un*)0)->sun_path)];
static void ctl_close(void){
    if(ctl_fd>=0){close(ctl_fd);ctl_fd=-1;unlink(ctl_path);}
    if(ctl_dir>=0){close(ctl_dir);ctl_dir=-1;}
}
static void ctl_open(void){
    if(!getenv("JARBOX_LAB_CONTROL")||strcmp(getenv("JARBOX_LAB_CONTROL"),"1"))return;
    char *dir=strdup(trace_path);if(!dir)return;
    char *slash=strrchr(dir,'/');
    if(slash){if(slash==dir)slash[1]=0;else *slash=0;}
    else strcpy(dir,".");
    char *absolute=realpath(dir,NULL);free(dir);if(!absolute)goto fail;
    ctl_dir=open(absolute,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);
    struct stat st;
    if(ctl_dir<0||fstat(ctl_dir,&st)||st.st_uid!=getuid()||(st.st_mode&077)){free(absolute);goto fail;}
    int n=snprintf(ctl_path,sizeof ctl_path,"%s/control.sock",absolute);free(absolute);
    if(n<0||(size_t)n>=sizeof ctl_path)goto fail;
    struct sockaddr_un a={0};a.sun_family=AF_UNIX;memcpy(a.sun_path,ctl_path,(size_t)n+1);
    int fd=socket(AF_UNIX,SOCK_DGRAM|SOCK_NONBLOCK|SOCK_CLOEXEC,0);
    if(fd<0)goto fail;
    mode_t old=umask(077);int rc=bind(fd,(struct sockaddr*)&a,sizeof a);umask(old);
    if(rc){close(fd);goto fail;}
    ctl_fd=fd;
    if(chmod(ctl_path,0600))goto fail;
    fprintf(stderr,"LAB_CONTROL_READY\n");return;
fail:
    ctl_close();fprintf(stderr,"LAB_CONTROL_UNAVAILABLE\n");
}
static cairo_status_t ctl_png_write(void *v,const unsigned char *data,unsigned n){
    return fwrite(data,1,n,v)==n?CAIRO_STATUS_SUCCESS:CAIRO_STATUS_WRITE_ERROR;
}
static int ctl_snapshot(void){
    size_t bytes=(size_t)width*height*4;
    unsigned char *copy=malloc(bytes);if(!copy)return 0;
    LOCK;memcpy(copy,frame,bytes);UNLOCK;
    int fd=openat(ctl_dir,"control-frame.tmp",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0){free(copy);return 0;}
    FILE *out=fdopen(fd,"wb");
    if(!out){close(fd);unlinkat(ctl_dir,"control-frame.tmp",0);free(copy);return 0;}
    cairo_surface_t *s=cairo_image_surface_create_for_data(copy,CAIRO_FORMAT_ARGB32,width,height,width*4);
    int ok=cairo_surface_write_to_png_stream(s,ctl_png_write,out)==CAIRO_STATUS_SUCCESS;
    cairo_surface_destroy(s);free(copy);
    if(fclose(out))ok=0;
    if(ok&&renameat(ctl_dir,"control-frame.tmp",ctl_dir,"control-frame.png"))ok=0;
    if(!ok)unlinkat(ctl_dir,"control-frame.tmp",0);
    return ok;
}
static int ctl_pair(Event a,Event b){
    int ok=0;LOCK;
    if(show_canvas&&wr-rd<=MAX_EVENTS-2&&!atomic_load(&stop_requested)){
        events[wr++%MAX_EVENTS]=a;events[wr++%MAX_EVENTS]=b;ok=1;
    }
    UNLOCK;return ok;
}
static SDL_Keycode ctl_key(const char *s){
    if(!strcmp(s,"up"))return SDLK_UP;if(!strcmp(s,"down"))return SDLK_DOWN;
    if(!strcmp(s,"left"))return SDLK_LEFT;if(!strcmp(s,"right"))return SDLK_RIGHT;
    if(!strcmp(s,"enter"))return SDLK_RETURN;if(!strcmp(s,"f1"))return SDLK_F1;
    if(!strcmp(s,"f2"))return SDLK_F2;if(!strcmp(s,"f3"))return SDLK_F3;
    if(strlen(s)==1&&s[0]>='0'&&s[0]<='9')return s[0];
    if(!strcmp(s,"star"))return SDLK_ASTERISK;if(!strcmp(s,"hash"))return SDLK_HASH;
    return 0;
}
static void ctl_poll(int physical){
    if(ctl_fd<0)return;
    for(int budget=0;budget<4;budget++){
        struct sockaddr_un peer={0};socklen_t len=sizeof peer;char req[96],reply[320];
        ssize_t n=recvfrom(ctl_fd,req,sizeof req-1,MSG_TRUNC,(struct sockaddr*)&peer,&len);
        if(n<0)return;
        if(n==0||n>=(ssize_t)sizeof req||memchr(req,0,(size_t)n))continue;
        req[n]=0;
        int canvas;unsigned queued;
        LOCK;canvas=show_canvas;queued=wr-rd;UNLOCK;
        int x=0,y=0,end=0;char key[16]={0};
        const char *state="refused";
        if(!strcmp(req,"status"))state="ok";
        else if(!strcmp(req,"snapshot"))state=ctl_snapshot()?"ok":"snapshot_failed";
        else if(!strcmp(req,"stop")){atomic_store(&stop_requested,1);state="stopping";}
        else if(physical)state="physical_input_active";
        else if(atomic_load(&stop_requested))state="stopping";
        else if(sscanf(req,"tap %4d %4d%n",&x,&y,&end)==2&&end==n){
            if(x>=0&&x<width&&y>=0&&y<height&&atomic_load(&frames)&&canvas)
                state=ctl_pair((Event){0,x,y,0},(Event){2,x,y,0})?"queued":"busy";
        }else if(sscanf(req,"key %15s%n",key,&end)==1&&end==n){
            SDL_Keycode k=ctl_key(key);
            if(k){
                SDL_Event e={0};e.type=SDL_KEYDOWN;e.key.keysym.sym=k;
                if(!canvas)state=ui_handle_event(&e)?"queued":"refused";
                else if(keycode(k)&&atomic_load(&frames)){
                    int code=keycode(k);state=ctl_pair((Event){3,0,0,code},(Event){4,0,0,code})?"queued":"busy";
                }
            }
        }
        snprintf(reply,sizeof reply,"{\"state\":\"%s\",\"canvas\":%d,\"width\":%d,\"height\":%d,\"frames\":%llu,\"input_events\":%llu,\"queued_before\":%u}",
          state,canvas,width,height,(unsigned long long)atomic_load(&frames),(unsigned long long)atomic_load(&events_delivered),queued);
        if(len>offsetof(struct sockaddr_un,sun_path)&&len<=sizeof peer)
            (void)sendto(ctl_fd,reply,strlen(reply),MSG_DONTWAIT,(struct sockaddr*)&peer,len);
    }
}
