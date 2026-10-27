#include "stdafx.h"
#include "flac2mp3.h"
#include "resource.h"

#include <helpers/atl-misc.h>
#include <helpers/DarkMode.h>

// Settings live on their own page, Preferences > Tools > FLAC to MP3, stored as cfg_vars.

namespace {
	constexpr GUID guid_page = { 0x8a1d5a99, 0x3478, 0x47f4, { 0x80, 0x05, 0xd2, 0x6a, 0x85, 0x6f, 0xb3, 0xee } };

	constexpr GUID guid_overwrite = { 0x5b072c9d, 0x8afa, 0x43cc, { 0x9d, 0xa5, 0xc6, 0x82, 0x34, 0xeb, 0x0b, 0x03 } };
	constexpr GUID guid_threads = { 0xa58507b9, 0x416f, 0x4262, { 0xa0, 0xaf, 0x96, 0x7f, 0xc0, 0x3c, 0x9c, 0x9b } };
	constexpr GUID guid_lamePath = { 0xd32b084c, 0xe682, 0x465e, { 0xae, 0xf6, 0xeb, 0xa1, 0x39, 0x2f, 0x38, 0xc3 } };
	constexpr GUID guid_delete = { 0xe0f070a7, 0x6338, 0x4ef9, { 0x85, 0xf4, 0xa2, 0xd6, 0x7a, 0x79, 0xfc, 0xff } };
	constexpr GUID guid_fbPlaylists = { 0x3892079a, 0x770a, 0x49f8, { 0x89, 0x8a, 0xd4, 0x72, 0xfb, 0x85, 0x0f, 0x5c } };
	constexpr GUID guid_m3u = { 0x9b05930c, 0x7a9e, 0x4f33, { 0x9c, 0x89, 0x64, 0x4c, 0x8e, 0x17, 0x9f, 0xa0 } };
	constexpr GUID guid_mainFolder = { 0x7aa77fef, 0xef72, 0x4600, { 0x93, 0x2b, 0x1f, 0x30, 0x04, 0x63, 0x69, 0xb2 } };
	constexpr GUID guid_keepBackup = { 0x3da0617c, 0x92e2, 0x42fd, { 0xb6, 0xfb, 0x7b, 0x12, 0x5f, 0x47, 0x8f, 0x8d } };

	// Test builds (cl /DFLAC2MP3_TEST) default to deleting sources so the whole flow runs without Preferences clicks.
#ifdef FLAC2MP3_TEST
	constexpr bool kDefaultDelete = true;
#else
	constexpr bool kDefaultDelete = false;
#endif

	flac2mp3::Settings Defaults() {
		flac2mp3::Settings s;
		s.deleteSource = kDefaultDelete;
		return s;
	}

	const flac2mp3::Settings kDefaults = Defaults();

	cfg_var_modern::cfg_bool cfg_overwrite(guid_overwrite, kDefaults.overwrite);
	cfg_var_modern::cfg_int cfg_threads(guid_threads, kDefaults.threads);
	cfg_var_modern::cfg_string cfg_lamePath(guid_lamePath, "");
	cfg_var_modern::cfg_bool cfg_delete(guid_delete, kDefaults.deleteSource);
	cfg_var_modern::cfg_bool cfg_fbPlaylists(guid_fbPlaylists, kDefaults.updateFoobarPlaylists);
	cfg_var_modern::cfg_bool cfg_m3u(guid_m3u, kDefaults.updateM3uFiles);
	cfg_var_modern::cfg_string cfg_mainFolder(guid_mainFolder, "");
	cfg_var_modern::cfg_bool cfg_keepBackup(guid_keepBackup, kDefaults.keepBackup);

	bool operator==(const flac2mp3::Settings& a, const flac2mp3::Settings& b) {
		return a.overwrite == b.overwrite && a.threads == b.threads && a.lamePath == b.lamePath
			&& a.deleteSource == b.deleteSource && a.updateFoobarPlaylists == b.updateFoobarPlaylists
			&& a.updateM3uFiles == b.updateM3uFiles && a.mainFolder == b.mainFolder && a.keepBackup == b.keepBackup;
	}

	flac2mp3::Settings Stored() {
		flac2mp3::Settings s;
		s.overwrite = cfg_overwrite;
		s.threads = static_cast<unsigned>(cfg_threads.get());
		s.lamePath = cfg_lamePath.get();
		s.deleteSource = cfg_delete;
		s.updateFoobarPlaylists = cfg_fbPlaylists;
		s.updateM3uFiles = cfg_m3u;
		s.mainFolder = cfg_mainFolder.get();
		s.keepBackup = cfg_keepBackup;
		return s;
	}

	class CPreferences : public CDialogImpl<CPreferences>, public preferences_page_instance {
	public:
		CPreferences(preferences_page_callback::ptr callback) : m_callback(callback) {}

		enum { IDD = IDD_PREFERENCES };

		t_uint32 get_state() override {
			t_uint32 state = preferences_state::resettable | preferences_state::dark_mode_supported;
			if (!(ReadUi() == Stored())) state |= preferences_state::changed;
			return state;
		}

		void apply() override {
			const flac2mp3::Settings s = ReadUi();
			cfg_overwrite = s.overwrite;
			cfg_threads = s.threads;
			cfg_lamePath = s.lamePath;
			cfg_delete = s.deleteSource;
			cfg_fbPlaylists = s.updateFoobarPlaylists;
			cfg_m3u = s.updateM3uFiles;
			cfg_mainFolder = s.mainFolder;
			cfg_keepBackup = s.keepBackup;
			m_callback->on_state_changed();
		}

		void reset() override {
			WriteUi(kDefaults);
			OnChanged();
		}

		BEGIN_MSG_MAP_EX(CPreferences)
			MSG_WM_INITDIALOG(OnInitDialog)
			COMMAND_HANDLER_EX(IDC_THREADS, EN_CHANGE, OnEdit)
			COMMAND_HANDLER_EX(IDC_LAME_PATH, EN_CHANGE, OnEdit)
			COMMAND_HANDLER_EX(IDC_MAIN_FOLDER, EN_CHANGE, OnEdit)
			COMMAND_HANDLER_EX(IDC_OVERWRITE, BN_CLICKED, OnEdit)
			COMMAND_HANDLER_EX(IDC_DELETE, BN_CLICKED, OnEdit)
			COMMAND_HANDLER_EX(IDC_FB_PLAYLISTS, BN_CLICKED, OnEdit)
			COMMAND_HANDLER_EX(IDC_M3U, BN_CLICKED, OnEdit)
			COMMAND_HANDLER_EX(IDC_KEEP_BAK, BN_CLICKED, OnEdit)
			COMMAND_HANDLER_EX(IDC_LAME_BROWSE, BN_CLICKED, OnBrowseLame)
			COMMAND_HANDLER_EX(IDC_MAIN_BROWSE, BN_CLICKED, OnBrowseMainFolder)
		END_MSG_MAP()

	private:
		BOOL OnInitDialog(CWindow, LPARAM) {
			m_dark.AddDialogWithControls(*this);
			WriteUi(Stored());
			return FALSE;
		}

		void OnEdit(UINT, int, CWindow) { OnChanged(); }

		void OnBrowseLame(UINT, int, CWindow) {
			pfc::string8 path = uGetDlgItemText(*this, IDC_LAME_PATH);
			if (uGetOpenFileName(*this, "lame.exe|lame.exe|Programs (*.exe)|*.exe", 0, "exe", "Locate lame.exe", nullptr, path, FALSE)) {
				uSetDlgItemText(*this, IDC_LAME_PATH, path);
			}
		}

		void OnBrowseMainFolder(UINT, int, CWindow) {
			pfc::string8 path = uGetDlgItemText(*this, IDC_MAIN_FOLDER);
			if (uBrowseForFolder(*this, "Main folder for .m3u / .m3u8 files", path)) {
				uSetDlgItemText(*this, IDC_MAIN_FOLDER, path);
			}
		}

		flac2mp3::Settings ReadUi() {
			flac2mp3::Settings s;
			s.overwrite = IsDlgButtonChecked(IDC_OVERWRITE) == BST_CHECKED;
			s.threads = GetDlgItemInt(IDC_THREADS, nullptr, FALSE);
			s.lamePath = uGetDlgItemText(*this, IDC_LAME_PATH);
			s.deleteSource = IsDlgButtonChecked(IDC_DELETE) == BST_CHECKED;
			s.updateFoobarPlaylists = IsDlgButtonChecked(IDC_FB_PLAYLISTS) == BST_CHECKED;
			s.updateM3uFiles = IsDlgButtonChecked(IDC_M3U) == BST_CHECKED;
			s.mainFolder = uGetDlgItemText(*this, IDC_MAIN_FOLDER);
			s.keepBackup = IsDlgButtonChecked(IDC_KEEP_BAK) == BST_CHECKED;
			s.lamePath.skip_trailing_char(' ');
			s.mainFolder.skip_trailing_char(' ');
			return s;
		}

		void WriteUi(const flac2mp3::Settings& s) {
			CheckDlgButton(IDC_OVERWRITE, s.overwrite ? BST_CHECKED : BST_UNCHECKED);
			SetDlgItemInt(IDC_THREADS, s.threads, FALSE);
			uSetDlgItemText(*this, IDC_LAME_PATH, s.lamePath);
			CheckDlgButton(IDC_DELETE, s.deleteSource ? BST_CHECKED : BST_UNCHECKED);
			CheckDlgButton(IDC_FB_PLAYLISTS, s.updateFoobarPlaylists ? BST_CHECKED : BST_UNCHECKED);
			CheckDlgButton(IDC_M3U, s.updateM3uFiles ? BST_CHECKED : BST_UNCHECKED);
			uSetDlgItemText(*this, IDC_MAIN_FOLDER, s.mainFolder);
			CheckDlgButton(IDC_KEEP_BAK, s.keepBackup ? BST_CHECKED : BST_UNCHECKED);
			UpdateEnabled();
		}

		// Playlist options only apply when deleting; the folder and backup options only with the playlist-file option.
		void UpdateEnabled() {
			const bool del = IsDlgButtonChecked(IDC_DELETE) == BST_CHECKED;
			const bool m3u = del && IsDlgButtonChecked(IDC_M3U) == BST_CHECKED;
			GetDlgItem(IDC_FB_PLAYLISTS).EnableWindow(del);
			GetDlgItem(IDC_M3U).EnableWindow(del);
			for (int id : { IDC_MAIN_FOLDER, IDC_MAIN_BROWSE, IDC_KEEP_BAK }) GetDlgItem(id).EnableWindow(m3u);
		}

		void OnChanged() {
			UpdateEnabled();
			m_callback->on_state_changed();
		}

		const preferences_page_callback::ptr m_callback;
		fb2k::CDarkModeHooks m_dark;
	};

	class PreferencesPage : public preferences_page_impl<CPreferences> {
	public:
		const char* get_name() override { return "FLAC to MP3"; }
		GUID get_guid() override { return guid_page; }
		GUID get_parent_guid() override { return guid_tools; }
	};

	preferences_page_factory_t<PreferencesPage> g_page;
}

flac2mp3::Settings flac2mp3::LoadSettings() {
	Settings s = Stored();
#ifdef FLAC2MP3_TEST
	char testMain[1024];
	size_t len = 0;
	if (s.mainFolder.is_empty() && getenv_s(&len, testMain, "FLAC2MP3_TEST_MAIN") == 0 && len > 1) s.mainFolder = testMain;
#endif
	return s;
}

void flac2mp3::ShowSettings() {
	ui_control::get()->show_preferences(guid_page);
}
