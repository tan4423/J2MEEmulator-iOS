#!/usr/bin/env python3
"""JarBox PC research launcher with persistent, non-gameplay settings."""
import datetime as dt
import hashlib
import json
import os
import pathlib
import subprocess
import tempfile
import tkinter as tk
from tkinter import ttk, filedialog, messagebox
import uuid
import zipfile
import importlib.util

ROOT=pathlib.Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location("jarbox_inspector", ROOT/"lab_inspector.py")
metrics=importlib.util.module_from_spec(spec)
spec.loader.exec_module(metrics)

DEFAULT_BASE=pathlib.Path.home()/".local/share/jarbox-lab"
CONFIG_DIR=pathlib.Path.home()/".config/jarbox-lab"
CONFIG_PATH=CONFIG_DIR/"settings.json"
DEFAULT_SETTINGS={
    "default_jar":"",
    "width":240,
    "height":320,
    "mode":"graph",
    "data_dir":str(DEFAULT_BASE),
    "refresh_ms":1000,
}
BASE=DEFAULT_BASE

def validate_settings(raw):
    """Validate user preferences; deliberately excludes gameplay/runtime knobs."""
    raw=raw if isinstance(raw,dict) else {}
    out=dict(DEFAULT_SETTINGS)
    default_jar=raw.get("default_jar",out["default_jar"])
    if not isinstance(default_jar,str) or "\x00" in default_jar or len(default_jar)>4096:
        raise ValueError("Invalid default JAR path")
    out["default_jar"]=default_jar
    for key in ("width","height"):
        value=raw.get(key,out[key])
        if isinstance(value,bool) or not isinstance(value,int) or not 64<=value<=2048:
            raise ValueError(f"{key} must be an integer from 64 to 2048")
        out[key]=value
    mode=raw.get("mode",out["mode"])
    if mode not in ("graph","plain"):
        raise ValueError("Mode must be graph or plain")
    out["mode"]=mode
    refresh=raw.get("refresh_ms",out["refresh_ms"])
    if isinstance(refresh,bool) or not isinstance(refresh,int) or refresh not in (500,1000,2000,5000):
        raise ValueError("Live refresh must be 500, 1000, 2000 or 5000 ms")
    out["refresh_ms"]=refresh
    data_dir=raw.get("data_dir",out["data_dir"])
    if not isinstance(data_dir,str) or not data_dir.strip() or "\x00" in data_dir or len(data_dir)>4096:
        raise ValueError("Invalid research data directory")
    out["data_dir"]=str(pathlib.Path(data_dir).expanduser())
    if not pathlib.Path(out["data_dir"]).is_absolute():
        raise ValueError("Research data directory must be an absolute path")
    return out

def load_settings():
    try:
        with CONFIG_PATH.open("r",encoding="utf-8") as f:
            return validate_settings(json.load(f))
    except FileNotFoundError:
        return dict(DEFAULT_SETTINGS)
    except (OSError,ValueError,TypeError,json.JSONDecodeError):
        return dict(DEFAULT_SETTINGS)

def save_settings(settings):
    values=validate_settings(settings)
    CONFIG_DIR.mkdir(parents=True,exist_ok=True,mode=0o700)
    os.chmod(CONFIG_DIR,0o700)
    fd,tmp=tempfile.mkstemp(prefix="settings-",suffix=".tmp",dir=CONFIG_DIR)
    try:
        with os.fdopen(fd,"w",encoding="utf-8") as f:
            json.dump(values,f,indent=2,ensure_ascii=False)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp,0o600)
        os.replace(tmp,CONFIG_PATH)
    finally:
        try: os.unlink(tmp)
        except FileNotFoundError: pass
    return values

def set_data_root(path):
    global BASE
    target=pathlib.Path(path).expanduser()
    if not target.is_absolute():
        raise ValueError("Research data directory must be absolute")
    if target.exists() and target.is_symlink():
        raise ValueError("Research data directory cannot be a symbolic link")
    target.mkdir(parents=True,exist_ok=True,mode=0o700)
    if not target.is_dir():
        raise ValueError("Research data path is not a directory")
    BASE=target
    return target

class Lab:
    def __init__(self,root):
        self.root=root; self.proc=None; self.session=None; self.log=None
        self.settings=load_settings()
        self.refresh_ms=self.settings["refresh_ms"]
        try:
            set_data_root(self.settings["data_dir"])
        except (OSError,ValueError):
            self.settings=dict(DEFAULT_SETTINGS)
            set_data_root(self.settings["data_dir"])
        root.title("JarBox PC — Research Lab")
        root.geometry("780x680");root.minsize(660,520)
        box=ttk.Frame(root,padding=14);box.pack(fill="both",expand=True)
        header=ttk.Frame(box);header.pack(fill="x")
        ttk.Label(header,text="JarBox PC / Research Lab",font=("Sans",18,"bold")).pack(side="left",anchor="w")
        self.settings_btn=ttk.Button(header,text="Settings",command=self.open_settings)
        self.settings_btn.pack(side="right")
        ttk.Label(box,text="Compatible baseline • real MiniJVM • no Deep Treo admission").pack(anchor="w",pady=(0,12))
        self.jar=tk.StringVar(value=self.settings["default_jar"]);row=ttk.Frame(box);row.pack(fill="x")
        ttk.Entry(row,textvariable=self.jar).pack(side="left",fill="x",expand=True)
        ttk.Button(row,text="Open JAR",command=self.pick).pack(side="left",padx=6)
        row=ttk.Frame(box);row.pack(fill="x",pady=10)
        self.mode=tk.StringVar(value=self.settings["mode"])
        ttk.Radiobutton(row,text="Research (graph + effects)",variable=self.mode,value="graph").pack(side="left")
        ttk.Radiobutton(row,text="CPU baseline",variable=self.mode,value="plain").pack(side="left",padx=10)
        self.w=tk.StringVar(value=str(self.settings["width"]));self.h=tk.StringVar(value=str(self.settings["height"]))
        ttk.Label(row,text="Screen").pack(side="left",padx=(8,3))
        ttk.Entry(row,textvariable=self.w,width=5).pack(side="left")
        ttk.Label(row,text="×").pack(side="left")
        ttk.Entry(row,textvariable=self.h,width=5).pack(side="left")
        row=ttk.Frame(box);row.pack(fill="x")
        self.start_btn=ttk.Button(row,text="Start game",command=self.start);self.start_btn.pack(side="left")
        ttk.Button(row,text="Export research ZIP",command=self.export).pack(side="left",padx=6)
        ttk.Button(row,text="Open session folder",command=self.folder).pack(side="left")
        self.status=tk.StringVar(value="Select your original Nick JAR.")
        ttk.Label(box,textvariable=self.status,wraplength=720).pack(anchor="w",pady=10)
        self.view=tk.Text(box,wrap="none",height=20,font=("Monospace",10))
        self.view.pack(fill="both",expand=True);self.view.configure(state="disabled")
        ttk.Label(box,text="Game: arrows / digits / Enter / F1 F2; F3 cycles modal commands; Esc closes game.").pack(anchor="w",pady=5)
        ttk.Label(box,text="Exports omit game JAR, RMS, raw JVM logs and login data.",wraplength=720).pack(anchor="w")
        root.protocol("WM_DELETE_WINDOW",self.close);root.after(self.refresh_ms,self.poll)

    def pick(self):
        name=filedialog.askopenfilename(filetypes=[("Java ME archive","*.jar"),("All files","*")])
        if name:self.jar.set(name)

    def _settings_values(self):
        try: width=int(self.w.get());height=int(self.h.get())
        except ValueError: raise ValueError("Screen width and height must be whole numbers")
        return validate_settings({
            "default_jar":self.jar.get(),"width":width,"height":height,
            "mode":self.mode.get(),"data_dir":str(BASE),"refresh_ms":self.refresh_ms,
        })

    def _apply_settings(self,raw):
        values=validate_settings(raw)
        if self.proc and self.proc.poll() is None and pathlib.Path(values["data_dir"])!=BASE:
            raise ValueError("Stop the game before changing the research data directory")
        new_base=set_data_root(values["data_dir"])
        self.settings=save_settings(values)
        self.refresh_ms=values["refresh_ms"]
        self.jar.set(values["default_jar"])
        self.w.set(str(values["width"]));self.h.set(str(values["height"]))
        self.mode.set(values["mode"])
        return new_base

    def open_settings(self):
        if self.proc and self.proc.poll() is None:
            return messagebox.showinfo("Settings","Stop the game before changing settings.")
        win=tk.Toplevel(self.root);win.title("JarBox PC — Settings");win.resizable(False,False)
        win.transient(self.root);win.grab_set()
        box=ttk.Frame(win,padding=16);box.pack(fill="both",expand=True)
        ttk.Label(box,text="Research Lab settings",font=("Sans",15,"bold")).grid(row=0,column=0,columnspan=3,sticky="w",pady=(0,12))
        jar=tk.StringVar(value=self.jar.get())
        data=tk.StringVar(value=str(BASE))
        width=tk.StringVar(value=self.w.get());height=tk.StringVar(value=self.h.get())
        mode=tk.StringVar(value=self.mode.get());refresh=tk.StringVar(value=str(self.refresh_ms))
        ttk.Label(box,text="Default game JAR").grid(row=1,column=0,sticky="w",pady=5)
        ttk.Entry(box,textvariable=jar,width=54).grid(row=1,column=1,sticky="ew",padx=6)
        def choose_jar():
            value=filedialog.askopenfilename(parent=win,filetypes=[("Java ME archive","*.jar"),("All files","*")])
            if value:jar.set(value)
        ttk.Button(box,text="Browse…",command=choose_jar).grid(row=1,column=2)
        ttk.Label(box,text="Research data / RMS root").grid(row=2,column=0,sticky="w",pady=5)
        ttk.Entry(box,textvariable=data,width=54).grid(row=2,column=1,sticky="ew",padx=6)
        def choose_data():
            value=filedialog.askdirectory(parent=win,initialdir=data.get() or str(pathlib.Path.home()))
            if value:data.set(value)
        ttk.Button(box,text="Browse…",command=choose_data).grid(row=2,column=2)
        ttk.Label(box,text="Game screen").grid(row=3,column=0,sticky="w",pady=5)
        dims=ttk.Frame(box);dims.grid(row=3,column=1,sticky="w")
        ttk.Entry(dims,textvariable=width,width=8).pack(side="left")
        ttk.Label(dims,text=" × ").pack(side="left")
        ttk.Entry(dims,textvariable=height,width=8).pack(side="left")
        ttk.Label(box,text="Default trace mode").grid(row=4,column=0,sticky="w",pady=5)
        modes=ttk.Frame(box);modes.grid(row=4,column=1,sticky="w")
        ttk.Radiobutton(modes,text="Research graph + effects",variable=mode,value="graph").pack(side="left")
        ttk.Radiobutton(modes,text="CPU baseline",variable=mode,value="plain").pack(side="left",padx=8)
        ttk.Label(box,text="Live metrics refresh").grid(row=5,column=0,sticky="w",pady=5)
        ttk.Combobox(box,textvariable=refresh,values=("500","1000","2000","5000"),state="readonly",width=12).grid(row=5,column=1,sticky="w",padx=6)
        ttk.Separator(box).grid(row=6,column=0,columnspan=3,sticky="ew",pady=12)
        ttk.Label(box,text="Compatibility baseline (fixed; not user-tunable)",font=("Sans",10,"bold")).grid(row=7,column=0,columnspan=3,sticky="w")
        ttk.Label(box,text="Game profile: Apple/iPhone  •  MiniJVM heap: 128 MiB  •  GC period: 500 ms  •  heap trigger: 70%",wraplength=560).grid(row=8,column=0,columnspan=3,sticky="w",pady=4)
        ttk.Label(box,text="These runtime values stay fixed to avoid changing game timing or invalidating comparisons.",wraplength=560).grid(row=9,column=0,columnspan=3,sticky="w",pady=(0,12))
        actions=ttk.Frame(box);actions.grid(row=10,column=0,columnspan=3,sticky="e")
        def apply():
            try:
                raw={"default_jar":jar.get(),"data_dir":data.get(),"width":int(width.get()),"height":int(height.get()),
                     "mode":mode.get(),"refresh_ms":int(refresh.get())}
                self._apply_settings(raw)
            except (ValueError,OSError) as exc:
                messagebox.showerror("Invalid settings",str(exc),parent=win);return
            self.status.set("Settings saved. They will be used for the next game session.")
            win.destroy()
        def reset():
            jar.set("");data.set(str(DEFAULT_BASE));width.set("240");height.set("320");mode.set("graph");refresh.set("1000")
        ttk.Button(actions,text="Reset defaults",command=reset).pack(side="left",padx=6)
        ttk.Button(actions,text="Cancel",command=win.destroy).pack(side="left",padx=6)
        ttk.Button(actions,text="Save settings",command=apply).pack(side="left")
        box.columnconfigure(1,weight=1)
        win.bind("<Escape>",lambda _e:win.destroy())
        win.update_idletasks()
        x=self.root.winfo_rootx()+(self.root.winfo_width()-win.winfo_width())//2
        y=self.root.winfo_rooty()+(self.root.winfo_height()-win.winfo_height())//2
        win.geometry(f"+{max(0,x)}+{max(0,y)}")

    def start(self):
        if self.proc and self.proc.poll() is None:return
        try:
            p=pathlib.Path(self.jar.get()).expanduser().resolve(strict=True)
            w,h=int(self.w.get()),int(self.h.get())
            if not p.is_file() or p.suffix.lower()!=".jar" or ":" in str(p) or not (64<=w<=2048 and 64<=h<=2048):raise ValueError("Invalid JAR path or dimensions")
            with zipfile.ZipFile(p) as z:
                if "META-INF/MANIFEST.MF" not in z.namelist():raise ValueError("Missing MIDlet manifest")
            with p.open("rb") as f:digest=hashlib.file_digest(f,"sha256").hexdigest()
            save=BASE/"saves"/digest;save.mkdir(parents=True,exist_ok=True,mode=0o700)
            import fcntl
            self.save_lock=(save/".lab.lock").open("a")
            try:fcntl.flock(self.save_lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError:self.save_lock.close();raise ValueError("This JAR already has a running save session")
            self.session=BASE/"sessions"/(dt.datetime.now().strftime("%Y%m%d-%H%M%S")+"-"+uuid.uuid4().hex[:8])
            self.session.mkdir(parents=True,exist_ok=True,mode=0o700)
            current=self._settings_values()
            self.settings=save_settings(current)
            (self.session/"session.json").write_text(json.dumps({"jar_sha256":digest,"source_commit":(ROOT/"source-commit.txt").read_text().strip(),"width":w,"height":h,"mode":self.mode.get(),"runtime":"MiniJVM Linux x64","note":"Desktop renderer differs from iOS; no Deep Treo enabled"},indent=2))
            self.log=(self.session/"private-runtime.log").open("wb")
            env={k:v for k,v in os.environ.items() if not k.startswith("JARBOX_LAB_")}
            # The user-authorized research channel stays inside the owner-only session.
            if self.mode.get()=="graph":env["JARBOX_LAB_CONTROL"]="1"
            args=[ROOT/"jarbox-lab",ROOT/"jars/minijvm_rt.jar",ROOT/"jars/j2me_api.jar",p,save,self.session/"trace.csv",str(w),str(h),self.mode.get()]
            self.proc=subprocess.Popen([str(x) for x in args],cwd=save,stdout=self.log,stderr=subprocess.STDOUT,env=env,pass_fds=(self.save_lock.fileno(),))
            self.start_btn.configure(state="disabled");self.settings_btn.configure(state="disabled")
            self.status.set("Game running. Close its window to stop and flush trace.")
        except Exception as exc:
            if self.log:self.log.close();self.log=None
            if getattr(self,"save_lock",None) and not self.save_lock.closed:self.save_lock.close()
            messagebox.showerror("Start failed",str(exc))

    def poll(self):
        if self.session:
            try: data=metrics.report(self.session/"trace.csv",10)
            except (FileNotFoundError,ValueError,TypeError,KeyError):data={"status":"Waiting for complete samples"}
            self.view.configure(state="normal");self.view.delete("1.0","end");self.view.insert("1.0",json.dumps(data,indent=2,ensure_ascii=False));self.view.configure(state="disabled")
        if self.proc and self.proc.poll() is not None:
            code=self.proc.returncode;self.proc=None
            if self.log:self.log.close();self.log=None
            if getattr(self,"save_lock",None) and not self.save_lock.closed:self.save_lock.close()
            self.start_btn.configure(state="normal");self.settings_btn.configure(state="normal")
            self.status.set(f"Game exited (code {code}). Export research data; private log stays local.")
        self.root.after(self.refresh_ms,self.poll)

    def export(self):
        if not self.session:return messagebox.showinfo("Export","Start a session first.")
        if self.proc and self.proc.poll() is None:return messagebox.showinfo("Export","Close the game first for a complete trace.")
        path=filedialog.asksaveasfilename(defaultextension=".zip",initialfile="JarBox-research-"+self.session.name+".zip",filetypes=[("Research ZIP","*.zip")])
        if not path:return
        with zipfile.ZipFile(path,"w",zipfile.ZIP_DEFLATED) as z:
            for name in ("session.json","trace.csv","trace.csv.edges.tsv","trace.csv.effects.csv","trace.csv.network.csv"):
                f=self.session/name
                if f.is_file():z.write(f,name)
        messagebox.showinfo("Export","Research ZIP saved. No game JAR or raw log included.")

    def folder(self):
        if self.session:
            try:subprocess.Popen(["explorer.exe",subprocess.check_output(["wslpath","-w",str(self.session)],text=True).strip()])
            except (OSError,subprocess.CalledProcessError):messagebox.showinfo("Session",str(self.session))

    def close(self):
        if self.proc and self.proc.poll() is None:
            messagebox.showinfo("Game running","Close the game window first to preserve RMS and flush the trace.");return
        self.root.destroy()

if __name__=="__main__":
    root=tk.Tk();Lab(root);root.mainloop()
