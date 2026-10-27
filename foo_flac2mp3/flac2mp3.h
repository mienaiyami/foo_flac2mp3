#pragma once

namespace flac2mp3 {
	enum class Quality { CBR320, V0, V1, V2 };

	// Snapshot of Preferences > Tools > FLAC to MP3, taken on the main thread when a conversion starts.
	struct Settings {
		bool overwrite = true;
		bool deleteSource = false;
		bool updateFoobarPlaylists = true;
		bool updateM3uFiles = true;
		bool keepBackup = false;   // write <playlist>.bak before changing a .m3u/.m3u8
		pfc::string8 mainFolder;   // root scanned for .m3u/.m3u8; empty disables the rewrite
		pfc::string8 lamePath;     // empty = search PATH, then <foobar2000>\encoders
		unsigned threads = 0;      // 0 = one per CPU core
	};

	Settings LoadSettings();

	// Appends to %TEMP%\foo_flac2mp3_trace.log in test builds (FLAC2MP3_TEST); no-op otherwise.
#ifdef FLAC2MP3_TEST
	void Trace(const char* msg);
#else
	inline void Trace(const char*) {}
#endif
	void RunConversion(metadb_handle_list_cref items, Quality quality);
	void ShowSettings();
}
