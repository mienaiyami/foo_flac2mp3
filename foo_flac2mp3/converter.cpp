#include "stdafx.h"
#include "flac2mp3.h"
#include <helpers/input_helpers.h>

#pragma comment(lib, "shlwapi.lib")

namespace fs = std::filesystem;

// Test builds trace to %TEMP%\foo_flac2mp3_trace.log; release builds compile this away.
#ifdef FLAC2MP3_TEST
void flac2mp3::Trace(const char* msg) {
	wchar_t dir[MAX_PATH + 1];
	GetTempPathW(MAX_PATH + 1, dir);
	FILE* f = nullptr;
	if (_wfopen_s(&f, (std::wstring(dir) + L"foo_flac2mp3_trace.log").c_str(), L"ab") == 0 && f) { fprintf(f, "%s\n", msg); fclose(f); }
}
#endif

namespace flac2mp3 {
namespace {

std::wstring Wide(const char* s) { return std::wstring(pfc::stringcvt::string_wide_from_utf8(s).get_ptr()); }
pfc::string8 Utf8(const std::wstring& s) { return pfc::string8(pfc::stringcvt::string_utf8_from_wide(s.c_str()).get_ptr()); }

bool EndsWithI(const std::wstring& s, const wchar_t* suffix) {
	const size_t n = wcslen(suffix);
	return s.size() >= n && _wcsicmp(s.c_str() + s.size() - n, suffix) == 0;
}

// Case-insensitive key for comparing absolute Windows paths.
std::wstring PathKey(const fs::path& p) {
	std::wstring s = p.lexically_normal().wstring();
	if (!s.empty()) CharLowerBuffW(s.data(), static_cast<DWORD>(s.size()));
	return s;
}

const wchar_t* LameArgs(Quality q) {
	switch (q) {
	case Quality::CBR320: return L"-b 320";
	case Quality::V0: return L"-V 0";
	case Quality::V1: return L"-V 1";
	default: return L"-V 2";
	}
}

const char* QualityName(Quality q) {
	switch (q) {
	case Quality::CBR320: return "CBR 320";
	case Quality::V0: return "V0";
	case Quality::V1: return "V1";
	default: return "V2";
	}
}

pfc::string8 Win32Message(const char* what, const std::wstring& path) {
	const DWORD err = GetLastError();
	return PFC_string_formatter() << what << " " << Utf8(path).c_str() << " (Windows error " << static_cast<unsigned>(err) << ")";
}

// lame.exe: configured path, else PATH (as foobar2000 sees it), else <foobar2000>\encoders.
std::wstring FindLame(const pfc::string8& configured) {
	if (!configured.is_empty()) {
		std::wstring p = Wide(configured);
		if (GetFileAttributesW(p.c_str()) == INVALID_FILE_ATTRIBUTES) throw pfc::exception(PFC_string_formatter() << "lame.exe not found at " << configured);
		return p;
	}
	std::wstring buf(32768, L'\0');
	if (DWORD n = SearchPathW(nullptr, L"lame.exe", nullptr, static_cast<DWORD>(buf.size()), buf.data(), nullptr)) return buf.substr(0, n);
	const DWORD n = GetModuleFileNameW(nullptr, buf.data(), static_cast<DWORD>(buf.size()));
	fs::path p = fs::path(buf.substr(0, n)).parent_path() / L"encoders" / L"lame.exe";
	if (fs::exists(p)) return p.wstring();
	throw pfc::exception("lame.exe not found on PATH or in foobar2000\\encoders. Set its path in Preferences > Tools > FLAC to MP3.");
}

// Temp WAV/MP3/log files for one track; removed when the job ends.
struct TempFiles {
	std::wstring wav, mp3, log;
	TempFiles() {
		static std::atomic<unsigned> counter{ 0 };
		wchar_t dir[MAX_PATH + 1];
		GetTempPathW(MAX_PATH + 1, dir);
		const std::wstring base = std::wstring(dir) + L"foo_flac2mp3_" + std::to_wstring(GetCurrentProcessId()) + L"_" + std::to_wstring(counter++);
		wav = base + L".wav"; mp3 = base + L".mp3"; log = base + L".log";
	}
	~TempFiles() { DeleteFileW(wav.c_str()); DeleteFileW(mp3.c_str()); DeleteFileW(log.c_str()); }
};

// PCM WAV writer; sizes are patched into the header when finished.
class WavFile {
public:
	explicit WavFile(const std::wstring& path) {
		if (_wfopen_s(&m_f, path.c_str(), L"wb") != 0 || !m_f) throw pfc::exception("Cannot create temporary WAV file");
	}
	~WavFile() { if (m_f) fclose(m_f); }

	void begin(uint32_t rate, uint16_t channels, uint16_t bps) {
		m_rate = rate; m_channels = channels; m_bps = bps;
		writeHeader();
	}
	void write(const void* data, size_t bytes) {
		if (fwrite(data, 1, bytes, m_f) != bytes) throw pfc::exception("Writing the temporary WAV file failed (disk full?)");
		m_dataBytes += bytes;
	}
	void finish() {
		if (m_dataBytes > 0xFFFFFFFFull - 36) throw pfc::exception("Track too long for a WAV intermediate (over 4 GB)");
		fseek(m_f, 0, SEEK_SET);
		writeHeader();
		if (fclose(m_f) != 0) { m_f = nullptr; throw pfc::exception("Closing the temporary WAV file failed"); }
		m_f = nullptr;
	}

private:
	void writeHeader() {
		uint8_t h[44];
		auto put32 = [&](int o, uint32_t v) { for (int i = 0; i < 4; ++i) h[o + i] = static_cast<uint8_t>(v >> (8 * i)); };
		auto put16 = [&](int o, uint16_t v) { h[o] = static_cast<uint8_t>(v); h[o + 1] = static_cast<uint8_t>(v >> 8); };
		const uint16_t blockAlign = static_cast<uint16_t>(m_channels * m_bps / 8);
		memcpy(h, "RIFF", 4); put32(4, static_cast<uint32_t>(36 + m_dataBytes)); memcpy(h + 8, "WAVE", 4);
		memcpy(h + 12, "fmt ", 4); put32(16, 16); put16(20, 1 /* PCM */); put16(22, m_channels);
		put32(24, m_rate); put32(28, m_rate * blockAlign); put16(32, blockAlign); put16(34, m_bps);
		memcpy(h + 36, "data", 4); put32(40, static_cast<uint32_t>(m_dataBytes));
		if (fwrite(h, 1, sizeof(h), m_f) != sizeof(h)) throw pfc::exception("Writing the temporary WAV file failed");
	}

	FILE* m_f = nullptr;
	uint32_t m_rate = 0;
	uint16_t m_channels = 0, m_bps = 0;
	uint64_t m_dataBytes = 0;
};

// Runs lame.exe hidden, with only its log file inherited; terminates it on abort.
void RunProcess(const std::wstring& exe, const std::wstring& args, const std::wstring& logPath, abort_callback& abort) {
	std::wstring cmd = L"\"" + exe + L"\" " + args;

	SECURITY_ATTRIBUTES sa{ sizeof(sa), nullptr, TRUE };
	HANDLE log = CreateFileW(logPath.c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_DELETE, &sa, CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, nullptr);
	if (log == INVALID_HANDLE_VALUE) throw pfc::exception(Win32Message("Cannot create", logPath));

	// Restrict inheritance to the log handle so parallel jobs don't leak handles into each other's lame.exe.
	SIZE_T attrSize = 0;
	InitializeProcThreadAttributeList(nullptr, 1, 0, &attrSize);
	std::vector<char> attrBuf(attrSize);
	auto attrs = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attrBuf.data());
	InitializeProcThreadAttributeList(attrs, 1, 0, &attrSize);
	UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &log, sizeof(HANDLE), nullptr, nullptr);

	STARTUPINFOEXW si{};
	si.StartupInfo.cb = sizeof(si);
	si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
	si.StartupInfo.hStdOutput = log;
	si.StartupInfo.hStdError = log;
	si.lpAttributeList = attrs;

	PROCESS_INFORMATION pi{};
	const BOOL started = CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, TRUE,
		CREATE_NO_WINDOW | BELOW_NORMAL_PRIORITY_CLASS | EXTENDED_STARTUPINFO_PRESENT, nullptr, nullptr, &si.StartupInfo, &pi);
	const DWORD startErr = GetLastError();
	DeleteProcThreadAttributeList(attrs);
	CloseHandle(log);
	if (!started) throw pfc::exception(PFC_string_formatter() << "Cannot start lame.exe (Windows error " << static_cast<unsigned>(startErr) << ")");
	CloseHandle(pi.hThread);

	while (WaitForSingleObject(pi.hProcess, 100) == WAIT_TIMEOUT) {
		if (abort.is_aborting()) {
			TerminateProcess(pi.hProcess, 1);
			WaitForSingleObject(pi.hProcess, 5000);
			CloseHandle(pi.hProcess);
			throw exception_aborted();
		}
	}
	DWORD code = 1;
	GetExitCodeProcess(pi.hProcess, &code);
	CloseHandle(pi.hProcess);
	if (code != 0) {
		std::string text;
		FILE* f = nullptr;
		if (_wfopen_s(&f, logPath.c_str(), L"rb") == 0 && f) {
			char buf[4096]; size_t n;
			while ((n = fread(buf, 1, sizeof(buf), f)) > 0) text.append(buf, n);
			fclose(f);
		}
		for (char& c : text) if (static_cast<unsigned char>(c) < 32 || static_cast<unsigned char>(c) > 126) c = ' ';
		if (text.size() > 300) text = text.substr(text.size() - 300);
		throw pfc::exception(PFC_string_formatter() << "lame.exe failed (exit " << static_cast<unsigned>(code) << "): " << text.c_str());
	}
}

void CopyWriteTime(const std::wstring& from, const std::wstring& to) {
	HANDLE src = CreateFileW(from.c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, 0, nullptr);
	if (src == INVALID_HANDLE_VALUE) return;
	FILETIME ft;
	if (GetFileTime(src, nullptr, nullptr, &ft)) {
		HANDLE dst = CreateFileW(to.c_str(), FILE_WRITE_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, 0, nullptr);
		if (dst != INVALID_HANDLE_VALUE) { SetFileTime(dst, nullptr, nullptr, &ft); CloseHandle(dst); }
	}
	CloseHandle(src);
}

bool RecycleFile(const std::wstring& path) {
	std::wstring from = path;
	from.push_back(L'\0');   // SHFileOperation wants a double-NUL-terminated list
	SHFILEOPSTRUCTW op{};
	op.wFunc = FO_DELETE;
	op.pFrom = from.c_str();
	op.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI;
	return SHFileOperationW(&op) == 0 && !op.fAnyOperationsAborted && GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES;
}

// ---- .m3u / .m3u8 rewrite ------------------------------------------------------

std::string ReadAll(const fs::path& p) {
	HANDLE h = CreateFileW(p.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0, nullptr);
	if (h == INVALID_HANDLE_VALUE) throw pfc::exception(Win32Message("Cannot read", p.wstring()));
	LARGE_INTEGER size{};
	GetFileSizeEx(h, &size);
	std::string data(static_cast<size_t>(size.QuadPart), '\0');
	DWORD got = 0;
	const BOOL ok = data.empty() || ReadFile(h, data.data(), static_cast<DWORD>(data.size()), &got, nullptr);
	CloseHandle(h);
	if (!ok) throw pfc::exception(Win32Message("Cannot read", p.wstring()));
	data.resize(got);
	return data;
}

// Opens without CREATE_ALWAYS, which fails on hidden files.
void WriteAll(const fs::path& p, const std::string& data) {
	HANDLE h = CreateFileW(p.c_str(), GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr);
	if (h == INVALID_HANDLE_VALUE) throw pfc::exception(Win32Message("Cannot write", p.wstring()));
	DWORD written = 0;
	const BOOL ok = WriteFile(h, data.data(), static_cast<DWORD>(data.size()), &written, nullptr) && SetEndOfFile(h);
	CloseHandle(h);
	if (!ok || written != data.size()) throw pfc::exception(Win32Message("Cannot write", p.wstring()));
}

// Replaces entries that point at a converted FLAC (.flac -> .mp3), keeping each entry's
// relative/absolute form, the encoding, BOM and line endings. Returns the number of entries changed.
int RewriteM3u(const fs::path& playlist, const std::set<std::wstring>& converted, bool keepBackup) {
	const std::string bytes = ReadAll(playlist);
	const bool bom = bytes.size() >= 3 && static_cast<unsigned char>(bytes[0]) == 0xEF && static_cast<unsigned char>(bytes[1]) == 0xBB && static_cast<unsigned char>(bytes[2]) == 0xBF;
	const char* body = bytes.data() + (bom ? 3 : 0);
	const int bodyLen = static_cast<int>(bytes.size() - (bom ? 3 : 0));
	if (bodyLen == 0) return 0;

	UINT cp = CP_UTF8;
	if (!bom && MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, body, bodyLen, nullptr, 0) == 0) cp = CP_ACP;
	std::wstring text(MultiByteToWideChar(cp, 0, body, bodyLen, nullptr, 0), L'\0');
	MultiByteToWideChar(cp, 0, body, bodyLen, text.data(), static_cast<int>(text.size()));

	const fs::path dir = playlist.parent_path();
	std::wstring out;
	out.reserve(text.size());
	int changed = 0;
	size_t pos = 0;
	while (pos < text.size()) {
		size_t eol = text.find_first_of(L"\r\n", pos);
		if (eol == std::wstring::npos) eol = text.size();
		size_t next = eol;
		if (next < text.size()) next += (text[next] == L'\r' && next + 1 < text.size() && text[next + 1] == L'\n') ? 2 : 1;

		std::wstring line = text.substr(pos, eol - pos);
		const size_t b = line.find_first_not_of(L" \t");
		if (b != std::wstring::npos && line[b] != L'#') {
			const size_t e = line.find_last_not_of(L" \t");
			std::wstring entry = line.substr(b, e - b + 1);
			if (EndsWithI(entry, L".flac")) {
				if (_wcsnicmp(entry.c_str(), L"file:", 5) == 0) {
					std::wstring buf(32768, L'\0');
					DWORD n = static_cast<DWORD>(buf.size());
					entry = SUCCEEDED(PathCreateFromUrlW(entry.c_str(), buf.data(), &n, 0)) ? buf.substr(0, n) : std::wstring();
				}
				if (!entry.empty()) {
					fs::path p(entry);
					if (p.is_relative()) p = dir / p;
					if (converted.count(PathKey(p))) {
						line = line.substr(0, e + 1 - 5) + L".mp3" + line.substr(e + 1);
						++changed;
					}
				}
			}
		}
		out += line;
		out.append(text, eol, next - eol);
		pos = next;
	}
	if (changed == 0) return 0;

	std::string encoded(WideCharToMultiByte(cp, 0, out.data(), static_cast<int>(out.size()), nullptr, 0, nullptr, nullptr), '\0');
	WideCharToMultiByte(cp, 0, out.data(), static_cast<int>(out.size()), encoded.data(), static_cast<int>(encoded.size()), nullptr, nullptr);
	if (bom) encoded.insert(0, "\xEF\xBB\xBF");

	if (keepBackup) {
		const std::wstring bak = playlist.wstring() + L".bak";
		if (!CopyFileW(playlist.c_str(), bak.c_str(), FALSE)) throw pfc::exception(Win32Message("Cannot create backup", bak));
	}
	WriteAll(playlist, encoded);
	return changed;
}

// Scans root for .m3u/.m3u8 files, skipping dot-folders (hidden tool/versioning folders).
void UpdateM3uFiles(const std::wstring& root, const std::set<std::wstring>& converted, bool keepBackup, std::vector<pfc::string8>& log) {
	std::error_code ec;
	fs::recursive_directory_iterator it(root, fs::directory_options::skip_permission_denied, ec), end;
	if (ec) { log.push_back(PFC_string_formatter() << "FAIL  cannot scan main folder " << Utf8(root).c_str()); return; }
	for (; it != end; it.increment(ec)) {
		if (ec) { log.push_back(PFC_string_formatter() << "FAIL  scanning stopped: " << ec.message().c_str()); break; }
		const std::wstring name = it->path().filename().wstring();
		if (it->is_directory(ec)) {
			if (!name.empty() && name[0] == L'.') it.disable_recursion_pending();
			continue;
		}
		if (!EndsWithI(name, L".m3u") && !EndsWithI(name, L".m3u8")) continue;
		try {
			const int n = RewriteM3u(it->path(), converted, keepBackup);
			if (n > 0) log.push_back(PFC_string_formatter() << "LIST  " << Utf8(it->path().wstring()).c_str() << ": " << n << " entr" << (n == 1 ? "y" : "ies") << " updated" << (keepBackup ? " (.bak kept)" : ""));
		} catch (std::exception const& e) {
			log.push_back(PFC_string_formatter() << "FAIL  playlist " << Utf8(it->path().wstring()).c_str() << ": " << e.what());
		}
	}
}

// ---- conversion ----------------------------------------------------------------------

struct Job {
	enum class Status { Pending, Ok, Skipped, Failed, Cancelled };
	metadb_handle_ptr handle;
	std::wstring src, dest;
	Status status = Status::Pending;
	bool deleted = false;
	pfc::string8 message;
};

void ConvertOne(Job& job, const Settings& s, const std::wstring& lame, Quality q, abort_callback& abort) {
	if (!s.overwrite && GetFileAttributesW(job.dest.c_str()) != INVALID_FILE_ATTRIBUTES) {
		job.status = Job::Status::Skipped;
		job.message = "MP3 already exists";
		return;
	}
	TempFiles tmp;

	// 1. Decode to a temp WAV with foobar2000's own decoder; keep the source's tags.
	file_info_impl info;
	{
		input_helper input;
		input.open(nullptr, job.handle, input_flag_no_seeking | input_flag_no_looping | input_flag_simpledecode, abort);
		input.get_info(job.handle->get_subsong_index(), info, abort);
		const uint16_t bps = info.info_get_decoded_bps() > 16 ? 24 : 16;

		WavFile wav(tmp.wav);
		audio_chunk_impl_temporary chunk;
		mem_block_container_impl pcm;
		uint32_t rate = 0, channels = 0;
		while (input.run(chunk, abort)) {
			if (rate == 0) {
				rate = chunk.get_sample_rate();
				channels = chunk.get_channels();
				if (channels > 2) throw pfc::exception("more than 2 channels; LAME only encodes mono/stereo");
				wav.begin(rate, static_cast<uint16_t>(channels), bps);
			} else if (chunk.get_sample_rate() != rate || chunk.get_channels() != channels) {
				throw pfc::exception("sample rate or channel count changes mid-track");
			}
			chunk.toFixedPoint(pcm, bps, bps);
			wav.write(pcm.get_ptr(), pcm.get_size());
		}
		if (rate == 0) throw pfc::exception("no audio decoded");
		wav.finish();
	}

	// Embedded pictures, one per type foobar2000 knows (front, back, disc, icon, artist).
	std::vector<std::pair<GUID, album_art_data::ptr>> art;
	try {
		auto extractor = album_art_extractor::g_open(nullptr, job.handle->get_path(), abort);
		for (size_t i = 0; i < album_art_ids::num_types(); ++i) {
			const GUID id = album_art_ids::query_type(i);
			album_art_data::ptr data;
			if (extractor->query(id, data, abort)) art.emplace_back(id, data);
		}
	} catch (exception_aborted const&) { throw; } catch (std::exception const&) { /* no embedded art */ }

	// 2. Encode.
	std::wstring args = std::wstring(L"-S --noreplaygain ") + LameArgs(q) + L" \"" + tmp.wav + L"\" \"" + tmp.mp3 + L"\"";
	RunProcess(lame, args, tmp.log, abort);
	DeleteFileW(tmp.wav.c_str());

	// 3. Tags and art, written by foobar2000's own MP3 tag writer (same result as its Converter).
	const pfc::string8 mp3Path = PFC_string_formatter() << "file://" << Utf8(tmp.mp3).c_str();
	{
		file_info_impl out;
		out.copy_meta(info);
		out.set_replaygain(info.get_replaygain());
		input_info_writer::ptr writer;
		input_entry::g_open_for_info_write(writer, nullptr, mp3Path, abort);
		writer->set_info(0, out, abort);
		writer->commit(abort);
	}
	if (!art.empty()) {
		auto editor = album_art_editor::g_open(nullptr, mp3Path, abort);
		for (auto& [id, data] : art) editor->set(id, data, abort);
		editor->commit(abort);
	}

	// 4. Into place: copy next to the source as .mp3.tmp, then rename over any existing MP3.
	const std::wstring destTmp = job.dest + L".tmp";
	if (!MoveFileExW(tmp.mp3.c_str(), destTmp.c_str(), MOVEFILE_COPY_ALLOWED | MOVEFILE_REPLACE_EXISTING))
		throw pfc::exception(Win32Message("Cannot write", destTmp));
	if (!MoveFileExW(destTmp.c_str(), job.dest.c_str(), MOVEFILE_REPLACE_EXISTING)) {
		pfc::string8 msg = Win32Message("Cannot replace (file in use?)", job.dest);
		DeleteFileW(destTmp.c_str());
		throw pfc::exception(msg);
	}
	CopyWriteTime(job.src, job.dest);
	job.status = Job::Status::Ok;

	// 5. Source to the Recycle Bin.
	if (s.deleteSource) {
		job.deleted = RecycleFile(job.src);
		if (!job.deleted) job.message = "converted, but the FLAC could not be moved to the Recycle Bin (in use?)";
	}
}

class ConvertProcess : public threaded_process_callback {
public:
	ConvertProcess(std::vector<Job>&& jobs, Settings settings, Quality quality, std::vector<pfc::string8>&& log)
		: m_jobs(std::move(jobs)), m_settings(std::move(settings)), m_quality(quality), m_log(std::move(log)) {}

	void on_init(ctx_t) override {}

	void run(threaded_process_status& status, abort_callback& abort) override {
		std::wstring lame;
		try { lame = FindLame(m_settings.lamePath); } catch (std::exception const& e) { m_fatal = e.what(); return; }
		m_log.push_back(PFC_string_formatter() << "lame: " << Utf8(lame).c_str());

		const size_t count = m_jobs.size();
		unsigned threads = m_settings.threads ? m_settings.threads : (std::max)(1u, std::thread::hardware_concurrency());
		threads = static_cast<unsigned>(std::min<size_t>(threads, count));

		std::atomic<size_t> next{ 0 }, done{ 0 };
		std::vector<std::thread> pool;
		for (unsigned t = 0; t < threads; ++t) {
			pool.emplace_back([&] {
				for (;;) {
					const size_t i = next++;
					if (i >= count) return;
					Job& job = m_jobs[i];
					if (abort.is_aborting()) { job.status = Job::Status::Cancelled; ++done; continue; }
					{ std::lock_guard<std::mutex> lock(m_mutex); m_current = Utf8(job.src); }
					try { ConvertOne(job, m_settings, lame, m_quality, abort); }
					catch (exception_aborted const&) { job.status = Job::Status::Cancelled; }
					catch (std::exception const& e) { job.status = Job::Status::Failed; job.message = e.what(); }
					catch (...) { job.status = Job::Status::Failed; job.message = "unknown error"; }
					++done;
				}
			});
		}
		while (done < count) {
			status.set_progress(done, count);
			{ std::lock_guard<std::mutex> lock(m_mutex); status.set_item_path(m_current); }
			Sleep(150);
		}
		for (auto& t : pool) t.join();
		status.set_progress(count, count);

		// Playlist files are rewritten even after Cancel: the FLACs already recycled must not stay dangling.
		if (m_settings.deleteSource && m_settings.updateM3uFiles && !m_settings.mainFolder.is_empty()) {
			std::set<std::wstring> converted;
			for (auto& job : m_jobs) if (job.deleted) converted.insert(PathKey(job.src));
			if (!converted.empty()) {
				status.set_item("Updating .m3u/.m3u8 files...");
				UpdateM3uFiles(Wide(m_settings.mainFolder), converted, m_settings.keepBackup, m_log);
			}
		}
	}

	void on_done(ctx_t wnd, bool aborted) override {
		if (!m_fatal.is_empty()) { popup_message::g_complain("FLAC to MP3", m_fatal); return; }

		std::map<metadb_handle*, metadb_handle_ptr> replacements;
		metadb_handle_list written;
		auto db = metadb::get();
		size_t ok = 0, skipped = 0, failed = 0, cancelled = 0;
		pfc::string_formatter details;
		for (auto& job : m_jobs) {
			const pfc::string8 src = Utf8(job.src);
			switch (job.status) {
			case Job::Status::Ok: {
				++ok;
				metadb_handle_ptr mp3;
				db->handle_create_replace_path(mp3, job.handle, PFC_string_formatter() << "file://" << Utf8(job.dest).c_str());
				written.add_item(mp3);
				if (job.deleted) replacements[job.handle.get_ptr()] = mp3;
				if (!job.message.is_empty()) details << "WARN  " << src << ": " << job.message << "\n";
				break;
			}
			case Job::Status::Skipped: ++skipped; details << "SKIP  " << src << ": " << job.message << "\n"; break;
			case Job::Status::Failed: ++failed; details << "FAIL  " << src << ": " << job.message << "\n"; break;
			default: ++cancelled; break;
			}
		}

		// Swap FLAC -> MP3 in every foobar2000 playlist, same position; undoable per playlist.
		if (m_settings.deleteSource && m_settings.updateFoobarPlaylists && !replacements.empty()) {
			auto pm = playlist_manager::get();
			for (size_t p = 0; p < pm->get_playlist_count(); ++p) {
				metadb_handle_list items;
				pm->playlist_get_all_items(p, items);
				size_t changed = 0;
				const bool locked = (pm->playlist_lock_get_filter_mask(p) & playlist_lock::filter_replace) != 0;
				for (size_t i = 0; i < items.get_count(); ++i) {
					auto found = replacements.find(items[i].get_ptr());
					if (found == replacements.end()) continue;
					if (locked) { ++changed; continue; }
					if (changed == 0) pm->playlist_undo_backup(p);
					pm->playlist_replace_item(p, i, found->second);
					++changed;
				}
				if (changed) {
					pfc::string8 name;
					pm->playlist_get_name(p, name);
					if (locked) m_log.push_back(PFC_string_formatter() << "LOCK  playlist \"" << name << "\" is locked; " << changed << " item(s) left unchanged");
					else m_log.push_back(PFC_string_formatter() << "PLAY  playlist \"" << name << "\": " << changed << " item(s) replaced");
				}
			}
		}

		if (written.get_count() > 0)
			metadb_io_v2::get()->load_info_async(written, metadb_io::load_info_force, wnd, metadb_io_v2::op_flag_background | metadb_io_v2::op_flag_delay_ui, nullptr);

		pfc::string_formatter report;
		report << "Quality " << QualityName(m_quality) << ": " << ok << " converted, " << skipped << " skipped, " << failed << " failed";
		if (cancelled) report << ", " << cancelled << " cancelled";
		if (aborted) report << " (aborted)";
		report << "\n\n" << details;
		for (auto& line : m_log) report << line << "\n";

		FB2K_console_formatter() << "FLAC to MP3:\n" << report;
		popup_message::g_show(report, "FLAC to MP3", failed ? popup_message::icon_error : popup_message::icon_information);
	}

private:
	std::vector<Job> m_jobs;
	const Settings m_settings;
	const Quality m_quality;
	std::vector<pfc::string8> m_log;
	pfc::string8 m_fatal;
	std::mutex m_mutex;
	pfc::string8 m_current;
};

} // namespace

void RunConversion(metadb_handle_list_cref items, Quality quality) {
	Trace(PFC_string_formatter() << "RunConversion: " << items.get_count() << " item(s)");
	const Settings settings = LoadSettings();
	Trace(PFC_string_formatter() << "settings: delete=" << settings.deleteSource << " main=" << settings.mainFolder);
	std::vector<Job> jobs;
	std::vector<pfc::string8> log;
	std::set<std::wstring> seen;
	size_t notFlac = 0;

	for (size_t i = 0; i < items.get_count(); ++i) {
		const metadb_handle_ptr& h = items[i];
		pfc::string8 native;
		if (!filesystem::g_get_native_path(h->get_path(), native)) { ++notFlac; continue; }
		std::wstring path = Wide(native);
		if (!EndsWithI(path, L".flac")) { ++notFlac; continue; }
		if (h->get_subsong_index() != 0) {
			log.push_back(PFC_string_formatter() << "SKIP  " << native << ": multi-track FLAC (cue sheet) is not supported");
			continue;
		}
		if (!seen.insert(PathKey(path)).second) continue;
		Job job;
		job.handle = h;
		job.src = path;
		job.dest = path.substr(0, path.size() - 5) + L".mp3";
		jobs.push_back(std::move(job));
	}
	if (notFlac) log.push_back(PFC_string_formatter() << "SKIP  " << notFlac << " selected item(s) are not local .flac files");

	const HWND wnd = core_api::get_main_window();
	Trace(PFC_string_formatter() << "jobs: " << jobs.size());
	if (jobs.empty()) {
		pfc::string_formatter msg;
		msg << "No local FLAC files in the selection.\n";
		for (auto& line : log) msg << "\n" << line;
		popup_message::g_show(msg, "FLAC to MP3");
		return;
	}

	if (settings.deleteSource) {
		pfc::string_formatter msg;
		msg << jobs.size() << " FLAC file(s) will be converted to MP3 (" << QualityName(quality) << ") and each source FLAC moved to the Recycle Bin after a successful conversion.";
		if (settings.updateFoobarPlaylists) msg << "\n\nfoobar2000 playlists: FLAC entries will be replaced with the MP3 (Undo works per playlist).";
		if (settings.updateM3uFiles && !settings.mainFolder.is_empty()) {
			msg << "\n\n.m3u/.m3u8 files under " << settings.mainFolder << " will be updated";
			msg << (settings.keepBackup ? " (a .bak copy is kept)." : ".");
		}
		msg << "\n\nContinue?";
		if (uMessageBox(wnd, msg, "FLAC to MP3", MB_OKCANCEL | MB_ICONQUESTION) != IDOK) return;
	}

	auto process = fb2k::service_new<ConvertProcess>(std::move(jobs), settings, quality, std::move(log));
	threaded_process::g_run_modeless(process,
		threaded_process::flag_show_progress | threaded_process::flag_show_item | threaded_process::flag_show_abort,
		wnd, "Converting FLAC to MP3");
}

} // namespace flac2mp3
