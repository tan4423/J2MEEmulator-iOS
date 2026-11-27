/* Included by lab.c after the basic Canvas bridge. Single-VM UI state;
 * lock protects every field. Revision is carried in all modal events. */
enum { UI_MAX=256, UI_TEXT=1024, UI_COMMANDS=32 };
typedef struct {int type,max,constraints,selection,choices;char label[UI_TEXT],text[UI_TEXT];} UiItem;
typedef struct {int id;char label[UI_TEXT];} UiCommand;
static UiItem ui_items[UI_MAX];
static UiCommand ui_commands[UI_COMMANDS];
static char ui_title[UI_TEXT],ui_alert[UI_TEXT];
static char ui_pending[UI_MAX][UI_TEXT];
static unsigned char ui_has_pending[UI_MAX];
static int ui_revision,ui_type,ui_count,ui_cmds,ui_focus,ui_timeout;
static uint64_t ui_deadline;
static int ui_copy(char *dst,const char *src){
    if(!src)src="";
    if(strlen(src)>=UI_TEXT){unsupported("desktop UI string capacity");dst[0]=0;return 0;}
    strcpy(dst,src);return 1;
}
static void ui_event_locked(Event e){
    if(wr-rd>=MAX_EVENTS){event_overflow++;unsupported("input queue overflow");}
    else events[wr++%MAX_EVENTS]=e;
}
static void ui_line(cairo_t *c,int y,const char *s){
    cairo_move_to(c,5,y);cairo_show_text(c,s?s:"");
}
static void ui_render_locked(void){
    if(show_canvas)return;
    cairo_surface_t *surface=cairo_image_surface_create_for_data((unsigned char*)frame,CAIRO_FORMAT_ARGB32,width,height,width*4);
    cairo_t *c=cairo_create(surface);
    cairo_set_source_rgb(c,.12,.14,.17);cairo_paint(c);
    cairo_select_font_face(c,"sans",CAIRO_FONT_SLANT_NORMAL,CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(c,13);cairo_set_source_rgb(c,1,1,1);
    ui_line(c,17,ui_title);
    if(ui_type==2)ui_line(c,42,ui_alert);
    int lines=(height-65)/34;if(lines<1)lines=1;
    int first=ui_focus>=lines?ui_focus-lines+1:0;
    for(int i=first;i<ui_count&&i<first+lines;i++){
        UiItem *it=&ui_items[i];int y=35+(i-first)*34;
        if(i==ui_focus){cairo_set_source_rgb(c,.23,.35,.55);cairo_rectangle(c,0,y-12,width,33);cairo_fill(c);}
        cairo_set_source_rgb(c,1,1,1);ui_line(c,y,it->label);
        if(it->type==1&&(it->constraints&0x10000)){
            char mask[UI_TEXT];size_t n=strlen(it->text);memset(mask,'*',n);mask[n]=0;ui_line(c,y+15,mask);
        }else if(it->type==2){char choice[64];snprintf(choice,sizeof choice,"Choice %d / %d",it->selection+1,it->choices);ui_line(c,y+15,choice);}
        else ui_line(c,y+15,it->text);
    }
    if(ui_cmds){char commands[UI_TEXT*2+32];snprintf(commands,sizeof commands,"F1 %s  |  F2 %s",ui_commands[0].label,ui_commands[ui_cmds-1].label);ui_line(c,height-8,commands);}
    else ui_line(c,height-8,"Enter: select");
    cairo_destroy(c);cairo_surface_flush(surface);cairo_surface_destroy(surface);dirty=1;
}
FN(formBegin){
    char *title=string_copy(r,0);LOCK;
    if(ui_revision==INT_MAX){unsupported("UI revision overflow");}
    else ui_revision++;
    ui_type=I(1);ui_count=ui_cmds=ui_focus=0;ui_timeout=-1;ui_deadline=0;
    memset(ui_items,0,sizeof ui_items);memset(ui_commands,0,sizeof ui_commands);
    memset(ui_pending,0,sizeof ui_pending);memset(ui_has_pending,0,sizeof ui_has_pending);
    ui_alert[0]=0;ui_copy(ui_title,title);UNLOCK;free(title);OK;
}
static void ui_add(Runtime*r,int type,int max,int constraints){
    char *label=string_copy(r,0),*value=type==2?NULL:string_copy(r,1);
    LOCK;if(ui_count>=UI_MAX)unsupported("desktop UI item capacity");
    else {UiItem *i=&ui_items[ui_count++];i->type=type;i->max=max;i->constraints=constraints;i->selection=type==2?max:0;
        ui_copy(i->label,label);ui_copy(i->text,value);}
    UNLOCK;free(label);free(value);
}
FN(formAddStringItem){ui_add(r,0,0,0);OK;}
FN(formAddTextField){ui_add(r,1,I(2),I(3));OK;}
FN(formAddChoice){ui_add(r,2,I(1),0);OK;}
FN(formAddChoiceOption){LOCK;if(ui_count&&ui_items[ui_count-1].type==2)ui_items[ui_count-1].choices++;else unsupported("choice without item");UNLOCK;OK;}
FN(formAddCommand){
    char *label=string_copy(r,0);LOCK;
    if(ui_cmds>=UI_COMMANDS)unsupported("desktop UI command capacity");
    else {UiCommand*c=&ui_commands[ui_cmds++];c->id=I(3);ui_copy(c->label,label);}
    UNLOCK;free(label);OK;
}
FN(listAddItem){
    char *label=string_copy(r,0);LOCK;
    if(ui_count>=UI_MAX)unsupported("desktop list capacity");else{UiItem *i=&ui_items[ui_count++];i->type=3;ui_copy(i->label,label);}
    UNLOCK;free(label);OK;
}
FN(listSetLastIcon){/* Desktop list icon is presentation-only; report omission. */fprintf(stderr,"LAB_UI_LIMIT: list icon not displayed\n");OK;}
FN(setListType){/* Selection/activation events are interpreted by Java List. */OK;}
FN(setAlertText){char *s=string_copy(r,0);LOCK;ui_copy(ui_alert,s);ui_timeout=I(1);UNLOCK;free(s);OK;}
FN(screenRevision){LOCK;int v=ui_revision;UNLOCK;PI(v);OK;}
FN(showCanvas){LOCK;show_canvas=1;ui_deadline=0;UNLOCK;OK;}
FN(formShow){LOCK;show_canvas=0;ui_deadline=ui_type==2&&ui_timeout>0?ns(CLOCK_MONOTONIC)+(uint64_t)ui_timeout*1000000ull:0;
    for(int i=0;i<ui_count;i++)if(ui_items[i].type==1){ui_focus=i;break;}
    ui_render_locked();UNLOCK;OK;}
static void ui_command_locked(int cmd){
    if(cmd<0||cmd>=ui_cmds)return;
    for(int i=0;i<ui_count;i++){
        UiItem *it=&ui_items[i];if(it->type==1){ui_copy(ui_pending[i],it->text);ui_has_pending[i]=1;}
        else if(it->type==2){snprintf(ui_pending[i],UI_TEXT,"%d",it->selection);ui_has_pending[i]=1;}
    }
    if(ui_type==1&&ui_count)ui_event_locked((Event){11,ui_revision,-ui_focus-1,0});
    ui_event_locked((Event){10,ui_revision,ui_commands[cmd].id,0});
    ui_deadline=0;
}
/* Decode UTF-8 into UTF-16 using SDL's platform converter. The Java heap
 * allocation occurs after releasing the native state lock. */
FN(takeText){
    char s[UI_TEXT];int i=I(0),revision=I(1),have=0;
    LOCK;if(revision==ui_revision&&i>=0&&i<ui_count&&ui_has_pending[i]){
        strcpy(s,ui_pending[i]);memset(ui_pending[i],0,UI_TEXT);ui_has_pending[i]=0;have=1;}
    UNLOCK;
    Instance *a=NULL;
    if(have){char *p=SDL_iconv_string("UTF-16LE","UTF-8",s,strlen(s)+1);if(p){
        unsigned n=0;while(n<UI_TEXT&&((unsigned char)p[n*2]||p[n*2+1]))n++;
        a=jarray_create_by_type_index(r,n,DATATYPE_JCHAR);
        if(a)for(unsigned j=0;j<n;j++)((uint16_t*)a->arr_body)[j]=(unsigned char)p[2*j]|((uint16_t)(unsigned char)p[2*j+1]<<8);
        SDL_free(p);
    }else unsupported("UTF-8 to UTF-16");}
    memset(s,0,sizeof s);PR(a);OK;
}
static unsigned utf16_units(const char*s){
    unsigned n=0;for(const unsigned char*p=(const unsigned char*)s;*p;p++)if((*p&0xc0)!=0x80)n+=*p>=0xf0?2:1;
    return n;
}
static void ui_edit_locked(const char*s){
    if(ui_count<=0||ui_focus>=ui_count)return;
    UiItem *i=&ui_items[ui_focus];if(i->type!=1||(i->constraints&0x20000))return;
    size_t len=strlen(i->text),more=strlen(s);
    if(len+more>=UI_TEXT||i->max<0||utf16_units(i->text)+utf16_units(s)>(unsigned)i->max)return;
    int base=i->constraints&0xffff;
    if(base==2||base==3||base==5){for(size_t j=0;j<more;j++)if(!strchr("0123456789+-.#*",s[j]))return;}
    memcpy(i->text+len,s,more+1);
}
static int ui_handle_event(SDL_Event *e){
    LOCK;if(show_canvas){UNLOCK;return 0;}
    if(e->type==SDL_TEXTINPUT)ui_edit_locked(e->text.text);
    if(e->type==SDL_KEYDOWN){
        SDL_Keycode k=e->key.keysym.sym;
        if((k==SDLK_TAB||k==SDLK_DOWN)&&ui_count)ui_focus=(ui_focus+1)%ui_count;
        else if(k==SDLK_UP&&ui_count)ui_focus=(ui_focus+ui_count-1)%ui_count;
        else if((k==SDLK_LEFT||k==SDLK_RIGHT)&&ui_count){
            UiItem*i=&ui_items[ui_focus];if(i->type==2&&i->choices>0)i->selection=(i->selection+i->choices+(k==SDLK_LEFT?-1:1))%i->choices;
        }else if(k==SDLK_BACKSPACE&&ui_count){UiItem*i=&ui_items[ui_focus];size_t n=strlen(i->text);
            if(i->type==1&&!(i->constraints&0x20000)&&n){do{n--;}while(n&&((unsigned char)i->text[n]&0xc0)==0x80);i->text[n]=0;}}
        else if(k==SDLK_F1)ui_command_locked(0);
        else if(k==SDLK_F2)ui_command_locked(ui_cmds-1);
        else if(k==SDLK_RETURN){
            if(ui_type==1&&ui_count)ui_event_locked((Event){11,ui_revision,ui_focus,0});
            else if(ui_type==2&&!ui_cmds)ui_event_locked((Event){12,ui_revision,0,0});
            else ui_command_locked(0);
        }
    }
    if(e->type==SDL_TEXTINPUT||e->type==SDL_KEYDOWN)ui_render_locked();
    UNLOCK;return 1;
}
static void ui_tick(void){
    LOCK;if(ui_deadline&&ns(CLOCK_MONOTONIC)>=ui_deadline){ui_deadline=0;ui_event_locked((Event){12,ui_revision,0,0});}UNLOCK;
}
