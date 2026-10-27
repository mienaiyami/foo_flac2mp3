#include "stdafx.h"
#include "flac2mp3.h"

DECLARE_COMPONENT_VERSION(
	"FLAC to MP3",
	"1.0.0",
	"Converts FLAC tracks to MP3 next to the source with lame.exe, copying all metadata and album art "
	"with foobar2000's own tag writer.\n"
	"Optionally moves the source FLAC to the Recycle Bin and replaces it with the MP3 in foobar2000 "
	"playlists and in .m3u/.m3u8 files under a main folder.\n\n"
	"Settings: Preferences > Tools > FLAC to MP3."
);

VALIDATE_COMPONENT_FILENAME("foo_flac2mp3.dll");

FOOBAR2000_IMPLEMENT_CFG_VAR_DOWNGRADE;

namespace {
	// ---- Context menu: Convert to MP3 > ... ----
	constexpr GUID guid_group = { 0x531fc76b, 0x23c5, 0x4649, { 0x99, 0xfe, 0x59, 0x88, 0x5e, 0x9a, 0xdd, 0x32 } };
	contextmenu_group_popup_factory g_group(guid_group, contextmenu_groups::root, "Convert to MP3", 0);

	class ConvertMenu : public contextmenu_item_simple {
	public:
		enum { cmd_cbr320, cmd_v0, cmd_v1, cmd_v2, cmd_settings, cmd_total };

		GUID get_parent() override { return guid_group; }
		unsigned get_num_items() override { return cmd_total; }

		void get_item_name(unsigned index, pfc::string_base& out) override {
			static const char* const names[cmd_total] = { "CBR 320 kbps", "VBR V0", "VBR V1", "VBR V2", "Settings..." };
			out = names[index];
		}

		void context_command(unsigned index, metadb_handle_list_cref data, const GUID&) override {
			flac2mp3::Trace(PFC_string_formatter() << "context_command " << index << ", " << data.get_count() << " item(s)");
			if (index == cmd_settings) { flac2mp3::ShowSettings(); return; }
			try {
				flac2mp3::RunConversion(data, static_cast<flac2mp3::Quality>(index));
			} catch (std::exception const& e) {
				popup_message::g_complain("FLAC to MP3: could not start", e);
			}
		}

		GUID get_item_guid(unsigned index) override {
			// One GUID per command: a fixed base with the index in the last byte.
			GUID g = { 0xa6d78ff6, 0x06ba, 0x496d, { 0xb6, 0xd1, 0x50, 0x06, 0xeb, 0xa8, 0xbd, 0x00 } };
			g.Data4[7] = static_cast<unsigned char>(index);
			return g;
		}

		bool get_item_description(unsigned index, pfc::string_base& out) override {
			if (index == cmd_settings) out = "Opens Preferences > Tools > FLAC to MP3.";
			else {
				pfc::string8 name;
				get_item_name(index, name);
				out = PFC_string_formatter() << "Converts the selected FLAC tracks to MP3, " << name;
			}
			return true;
		}
	};

	contextmenu_item_factory_t<ConvertMenu> g_menu;
}
