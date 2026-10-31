// Opens the configured dictionary once on a fresh Windows installation.
// Rime's sync only merges databases that already exist. No input is committed.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class RimeDictionaryBootstrap {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
    [DllImport("kernel32.dll", CharSet=CharSet.Ansi)]
    private static extern IntPtr GetProcAddress(IntPtr library, string name);
    [DllImport("kernel32.dll")]
    private static extern bool FreeLibrary(IntPtr library);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate IntPtr GetApi();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void TraitsCall(ref Traits traits);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void FinalizeCall();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate UIntPtr CreateSession();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int DestroySession(UIntPtr session);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int SelectSchema(UIntPtr session, IntPtr schema);

    [StructLayout(LayoutKind.Sequential)]
    private struct Traits {
        public int data_size;
        public IntPtr shared_data_dir, user_data_dir, distribution_name;
        public IntPtr distribution_code_name, distribution_version, app_name, modules;
        public int min_log_level;
        public IntPtr log_dir, prebuilt_data_dir, staging_dir;
    }

    private static IntPtr Utf8(string text, List<IntPtr> memory) {
        byte[] bytes = Encoding.UTF8.GetBytes(text + "\0");
        IntPtr value = Marshal.AllocHGlobal(bytes.Length);
        Marshal.Copy(bytes, 0, value, bytes.Length);
        memory.Add(value);
        return value;
    }

    private static Delegate Function(IntPtr api, int index, Type type) {
        int header = IntPtr.Size == 8 ? 8 : 4;
        if (Marshal.ReadInt32(api) < header - 4 + (index + 1) * IntPtr.Size)
            throw new InvalidOperationException("Installed librime API is too old.");
        return Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(api, header + index * IntPtr.Size), type);
    }

    public static void Create(string libraryPath, string userDirectory, string sharedDirectory) {
        IntPtr library = LoadLibraryEx(libraryPath, IntPtr.Zero, 8);
        if (library == IntPtr.Zero) throw new InvalidOperationException("Unable to load the installed librime DLL.");
        var memory = new List<IntPtr>();
        bool initialized = false;
        FinalizeCall finalize = null;
        try {
            IntPtr entry = GetProcAddress(library, "rime_get_api");
            if (entry == IntPtr.Zero) throw new InvalidOperationException("librime API is unavailable.");
            IntPtr api = ((GetApi)Marshal.GetDelegateForFunctionPointer(entry, typeof(GetApi)))();
            var traits = new Traits();
            traits.data_size = Marshal.SizeOf(typeof(Traits)) - 4;
            traits.user_data_dir = Utf8(userDirectory, memory);
            traits.shared_data_dir = Utf8(sharedDirectory, memory);
            traits.prebuilt_data_dir = traits.shared_data_dir;
            traits.app_name = Utf8("rime.sync_bootstrap", memory);
            traits.log_dir = Utf8("", memory);
            traits.min_log_level = 2;
            traits.modules = Marshal.AllocHGlobal(IntPtr.Size * 3);
            memory.Add(traits.modules);
            Marshal.WriteIntPtr(traits.modules, 0, Utf8("default", memory));
            Marshal.WriteIntPtr(traits.modules, IntPtr.Size, Utf8("lua", memory));
            Marshal.WriteIntPtr(traits.modules, IntPtr.Size * 2, IntPtr.Zero);
            ((TraitsCall)Function(api, 0, typeof(TraitsCall)))(ref traits);
            ((TraitsCall)Function(api, 2, typeof(TraitsCall)))(ref traits);
            initialized = true;
            finalize = (FinalizeCall)Function(api, 3, typeof(FinalizeCall));
            UIntPtr session = ((CreateSession)Function(api, 13, typeof(CreateSession)))();
            if (session == UIntPtr.Zero) throw new InvalidOperationException("Unable to create the initial Rime session.");
            try {
                if (((SelectSchema)Function(api, 34, typeof(SelectSchema)))(session, Utf8("double_pinyin_flypy", memory)) == 0)
                    throw new InvalidOperationException("Unable to initialize the double-pinyin user dictionary.");
            } finally { ((DestroySession)Function(api, 15, typeof(DestroySession)))(session); }
        } finally {
            if (initialized && finalize != null) finalize();
            foreach (IntPtr pointer in memory) Marshal.FreeHGlobal(pointer);
            FreeLibrary(library);
        }
    }
}
