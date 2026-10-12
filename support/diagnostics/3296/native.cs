using System;
using System.Runtime.InteropServices;
using System.Text;
public static class Issue3456Native {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int command);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr FindResource(IntPtr module, IntPtr name, IntPtr type);
    [DllImport("kernel32.dll")] static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll")] static extern IntPtr LockResource(IntPtr resource);
    [DllImport("kernel32.dll")] static extern uint SizeofResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr module);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern int GetPackageFullName(IntPtr h, ref uint length, StringBuilder name);
    public static string ProcessPackage(uint pid) {
        IntPtr h = OpenProcess(0x1000, false, pid);
        if (h == IntPtr.Zero) return "OpenProcessError=" + Marshal.GetLastWin32Error();
        try {
            uint length = 0; int code = GetPackageFullName(h, ref length, null);
            if (code != 122) return "GetPackageFullNameCode=" + code;
            var name = new StringBuilder(checked((int)length));
            code = GetPackageFullName(h, ref length, name);
            return "GetPackageFullNameCode=" + code + ";Package=" + name;
        } finally { CloseHandle(h); }
    }
    public static byte[] EmbeddedManifest(string path) {
        // Data-file mapping reads RT_MANIFEST without running the executable.
        IntPtr h = LoadLibraryEx(path, IntPtr.Zero, 0x22);
        if (h == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
        try {
            IntPtr r = FindResource(h, new IntPtr(1), new IntPtr(24));
            if (r == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
            int n = checked((int)SizeofResource(h, r));
            byte[] bytes = new byte[n];
            Marshal.Copy(LockResource(LoadResource(h, r)), bytes, 0, n);
            return bytes;
        } finally { FreeLibrary(h); }
    }
}
public static class Clipboard3536 {
 [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool OpenClipboard(IntPtr h);
 [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool EmptyClipboard();
 [System.Runtime.InteropServices.DllImport("user32.dll")] static extern IntPtr SetClipboardData(uint format,IntPtr h);
 [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool CloseClipboard();
 [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern IntPtr GlobalAlloc(uint flags,UIntPtr bytes);
 [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr h);
 [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr h);
 [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern IntPtr GlobalFree(IntPtr h);
 public static void SetText(string s) {var b=System.Text.Encoding.Unicode.GetBytes(s+"\0");var h=GlobalAlloc(2,(UIntPtr)b.Length);if(h==IntPtr.Zero)throw new Exception("Clipboard allocation failed");bool transferred=false;try{var p=GlobalLock(h);if(p==IntPtr.Zero)throw new Exception("Clipboard lock failed");Marshal.Copy(b,0,p,b.Length);GlobalUnlock(h);if(!OpenClipboard(IntPtr.Zero))throw new Exception("Clipboard unavailable");try{if(!EmptyClipboard()||SetClipboardData(13,h)==IntPtr.Zero)throw new Exception("Clipboard input failed");transferred=true;}finally{CloseClipboard();}}finally{if(!transferred)GlobalFree(h);}}
}
public static class Volume3536 {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool GetVolumeInformation(string root,StringBuilder volume,int size,out uint serial,out uint maximum,out uint flags,StringBuilder fs,int fsSize);
 public static string Info(){uint serial,max,flags;var volume=new StringBuilder(260);var fs=new StringBuilder(260);if(!GetVolumeInformation("C:\\",volume,260,out serial,out max,out flags,fs,260))throw new System.ComponentModel.Win32Exception();if(fs.ToString()!="NTFS" || max<116)throw new Exception("Native volume/component prerequisite failed");return "FileSystem="+fs+";MaximumComponentUnits="+max+";Serial="+serial+";Flags="+flags;}
}
public static class NvdaKeys3296 {
 [DllImport("user32.dll")] static extern void keybd_event(byte key,byte scan,uint flags,UIntPtr extra);
 public static void Gesture(byte key){keybd_event(0x2d,0,1,UIntPtr.Zero);keybd_event(key,0,0,UIntPtr.Zero);keybd_event(key,0,2,UIntPtr.Zero);keybd_event(0x2d,0,3,UIntPtr.Zero);}
}
