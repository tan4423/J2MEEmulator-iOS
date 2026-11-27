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
        struct sockaddr_un peer={0};socklen_t len=sizeof peer;char req[96],reply[2400];
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
        else if(!strcmp(req,"profile counters")||!strcmp(req,"profile graph")){
            if(trace_graph){atomic_store(&jarbox_lab_trace_enabled,!strcmp(req,"profile graph"));state="ok";}
        }
        else if(!strcmp(req,"sink off")){atomic_store(&sink_requested,0);state="ok";}
        else if(!strcmp(req,"sink on")||!strcmp(req,"sink deep")||!strcmp(req,"sink glyph")||!strcmp(req,"sink map")||!strcmp(req,"sink ir")||!strcmp(req,"sink residual")){
            if(sink_admitted&&canvas&&atomic_load(&frames)&&!physical&&(!queued||sink_fixture)&&!atomic_load(&sink_invalid)){
                int level=!strcmp(req,"sink residual")?6:!strcmp(req,"sink ir")?5:!strcmp(req,"sink map")?4:!strcmp(req,"sink glyph")?3:!strcmp(req,"sink deep")?2:1;
                if(level==1||(deep_admitted&&(level!=6||!sink_fixture))){
                    atomic_store(&sink_requested,level);state="ok";
                }
            }
        }
        else if(physical)state="physical_input_active";
        else if(atomic_load(&sink_requested)&&!sink_fixture)state="render_paused";
        else if(atomic_load(&stop_requested))state="stopping";
        else if(!strncmp(req,"chat ",5)){
            /* Only the three explicitly requested research commands, into
             * an empty, non-password chat TextBox. Never edit credentials. */
            const char *value=req+5;
            if(!strcmp(value,"gm37")||!strcmp(value,"k27")||!strcmp(value,"ts")){
                LOCK;
                if(!show_canvas&&!strcasecmp(ui_title,"chat")&&ui_count==1&&ui_focus==0&&
                   ui_items[0].type==1&&!(ui_items[0].constraints&0x30000)&&
                   ui_items[0].text[0]==0){
                    ui_edit_locked(value);
                    if(!strcmp(ui_items[0].text,value)){ui_render_locked();state="queued";}
                }
                UNLOCK;
            }
        }
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
        snprintf(reply,sizeof reply,"{\"state\":\"%s\",\"canvas\":%d,\"width\":%d,\"height\":%d,\"frames\":%llu,\"input_events\":%llu,\"queued_before\":%u,\"paints\":%llu,\"sink_requested\":%d,\"sink_paints\":%llu,\"sink_draws\":%llu,\"sink_faults\":%llu,\"sink_invalid\":%d,\"deep_leaves\":%llu,\"glyph_attempts\":%llu,\"glyph_scope_refusals\":%llu,\"glyph_link_refusals\":%llu,\"glyph_data_refusals\":%llu,\"glyph_loops\":%llu,\"glyph_chars\":%llu,\"map_q3\":%llu,\"map_m3\":%llu,\"map_refusals\":%llu,\"residual_plans\":%llu,\"residual_calls\":%llu,\"residual_regions\":%llu,\"residual_deopts\":%llu,\"map_layout_builds\":%llu,\"map_layout_hits\":%llu,\"graph_enabled\":%d,\"ir_plans\":%llu,\"ir_spans\":%llu,\"ir_ops\":%llu,\"skill_advances_live\":%llu,\"network_calls_live\":%llu,\"update_calls_live\":%llu}",
          state,canvas,width,height,(unsigned long long)atomic_load(&frames),(unsigned long long)atomic_load(&events_delivered),queued,(unsigned long long)atomic_load(&paints),atomic_load(&sink_requested),(unsigned long long)atomic_load(&sink_paints),(unsigned long long)atomic_load(&sink_draws),(unsigned long long)atomic_load(&sink_faults),atomic_load(&sink_invalid),(unsigned long long)atomic_load(&deep_counts[0]),(unsigned long long)atomic_load(&deep_counts[1]),(unsigned long long)atomic_load(&deep_counts[2]),(unsigned long long)atomic_load(&deep_counts[3]),(unsigned long long)atomic_load(&deep_counts[4]),(unsigned long long)atomic_load(&deep_counts[5]),(unsigned long long)atomic_load(&deep_counts[6]),(unsigned long long)atomic_load(&deep_counts[7]),(unsigned long long)atomic_load(&deep_counts[8]),(unsigned long long)atomic_load(&deep_counts[9]),(unsigned long long)atomic_load(&deep_counts[10]),(unsigned long long)atomic_load(&deep_counts[11]),(unsigned long long)atomic_load(&deep_counts[12]),(unsigned long long)atomic_load(&deep_counts[13]),(unsigned long long)atomic_load(&deep_counts[14]),(unsigned long long)atomic_load(&deep_counts[15]),atomic_load(&jarbox_lab_trace_enabled),(unsigned long long)atomic_load(&logic_plans),(unsigned long long)atomic_load(&logic_spans),(unsigned long long)atomic_load(&logic_ops),(unsigned long long)atomic_load(&live_counts[0]),(unsigned long long)atomic_load(&live_counts[1]),(unsigned long long)atomic_load(&live_counts[2]));
        if(len>offsetof(struct sockaddr_un,sun_path)&&len<=sizeof peer)
            (void)sendto(ctl_fd,reply,strlen(reply),MSG_DONTWAIT,(struct sockaddr*)&peer,len);
    }
}
