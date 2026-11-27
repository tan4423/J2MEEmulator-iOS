#!/usr/bin/env python3
"""PC research launcher: one game process, private save, local trace export."""
import datetime as dt
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import tkinter as tk
from tkinter import ttk, filedialog, messagebox
import uuid
import zipfile
# Local inspector is intentionally loaded by path: do not shadow stdlib inspect.
import importlib.util
ROOT=pathlib.Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location("jarbox_inspector", ROOT/"lab_inspector.py")
metrics=importlib.util.module_from_spec(spec)
spec.loader.exec_module(metrics)
BASE=pathlib.Path.home()/".local/share/jarbox-lab"
BASE.mkdir(parents=True,exist_ok=True,mode=0o700)
class Lab:
    def __init__(self,root):
        self.root=root; self.proc=None; self.session=None;self.log=None
        root.title("JarBox PC — Research Lab")
        root.geometry("760x660");root.minsize(640,500)
        box=ttk.Frame(root,padding=14);box.pack(fill="both",expand=True)
        ttk.Label(box,text="JarBox PC / Research Lab",font=("Sans",18,"bold")).pack(anchor="w")
        ttk.Label(box,text="Compatible baseline • real MiniJVM • no Deep Treo admission").pack(anchor="w",pady=(0,12))
        self.jar=tk.StringVar();row=ttk.Frame(box);row.pack(fill="x")
        ttk.Entry(row,textvariable=self.jar).pack(side="left",fill="x",expand=True)
        ttk.Button(row,text="Open JAR",command=self.pick).pack(side="left",padx=6)
        row=ttk.Frame(box);row.pack(fill="x",pady=10)
        self.mode=tk.StringVar(value="graph")
        ttk.Radiobutton(row,text="Research (graph + effects)",variable=self.mode,value="graph").pack(side="left")
        ttk.Radiobutton(row,text="CPU baseline",variable=self.mode,value="plain").pack(side="left",padx=10)
        self.w=tk.StringVar(value="240");self.h=tk.StringVar(value="320")
        for var in (self.w,self.h):ttk.Entry(row,textvariable=var,width=5).pack(side="left")
        row=ttk.Frame(box);row.pack(fill="x")
        self.start_btn=ttk.Button(row,text="Start game",command=self.start);self.start_btn.pack(side="left")
        ttk.Button(row,text="Export research ZIP",command=self.export).pack(side="left",padx=6)
        ttk.Button(row,text="Open session folder",command=self.folder).pack(side="left")
        self.status=tk.StringVar(value="Select your original Nick JAR.")
        ttk.Label(box,textvariable=self.status,wraplength=700).pack(anchor="w",pady=10)
        self.view=tk.Text(box,wrap="none",height=20,font=("Monospace",10))
        self.view.pack(fill="both",expand=True);self.view.configure(state="disabled")
        ttk.Label(box,text="Game: arrows / digits / Enter / F1 F2; F3 cycles modal commands; Esc closes game.").pack(anchor="w",pady=5)
        ttk.Label(box,text="Exports omit game JAR, RMS, raw JVM logs and login data.",wraplength=700).pack(anchor="w")
        root.protocol("WM_DELETE_WINDOW",self.close);root.after(500,self.poll)
    def pick(self):
        name=filedialog.askopenfilename(filetypes=[("Java ME archive","*.jar"),("All files","*")])
        if name:self.jar.set(name)
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
            # Never allow two writers to the same RMS directory.
            import fcntl
            self.save_lock=(save/".lab.lock").open("a")
            try:fcntl.flock(self.save_lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError:self.save_lock.close();raise ValueError("This JAR already has a running save session")
            self.session=BASE/"sessions"/(dt.datetime.now().strftime("%Y%m%d-%H%M%S")+"-"+uuid.uuid4().hex[:8])
            self.session.mkdir(parents=True,mode=0o700)
            (self.session/"session.json").write_text(json.dumps({"jar_sha256":digest,"source_commit":(ROOT/"source-commit.txt").read_text().strip(),"width":w,"height":h,"mode":self.mode.get(),"runtime":"MiniJVM Linux x64","note":"Desktop renderer differs from iOS; no Deep Treo enabled"},indent=2))
            self.log=(self.session/"private-runtime.log").open("wb")
            env={k:v for k,v in os.environ.items() if not k.startswith("JARBOX_LAB_")}
            args=[ROOT/"jarbox-lab",ROOT/"jars/minijvm_rt.jar",ROOT/"jars/j2me_api.jar",p,save,self.session/"trace.csv",str(w),str(h),self.mode.get()]
            self.proc=subprocess.Popen([str(x) for x in args],cwd=save,stdout=self.log,stderr=subprocess.STDOUT,env=env,pass_fds=(self.save_lock.fileno(),))
            self.start_btn.configure(state="disabled");self.status.set("Game running. Close its window to stop and flush trace.")
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
            self.start_btn.configure(state="normal")
            self.status.set(f"Game exited (code {code}). Export research data; private log stays local.")
        self.root.after(1000,self.poll)
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
