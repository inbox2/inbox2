require "rails_helper"

RSpec.describe SubjectNormalizer do
  describe ".normalize" do
    # ---- Nil / empty / whitespace ----

    it "returns empty string for nil" do
      expect(described_class.normalize(nil)).to eq("")
    end

    it "returns empty string for empty string" do
      expect(described_class.normalize("")).to eq("")
    end

    it "returns empty string for whitespace-only" do
      expect(described_class.normalize("   ")).to eq("")
    end

    # ---- No prefix — passthrough ----

    it "returns subject unchanged when no prefix is present" do
      expect(described_class.normalize("Meeting notes")).to eq("Meeting notes")
    end

    it "preserves internal whitespace" do
      expect(described_class.normalize("Q3 Budget   Review")).to eq("Q3 Budget Review")
    end

    # ---- English Re: / Fwd: ----

    it "strips Re:" do
      expect(described_class.normalize("Re: Hello")).to eq("Hello")
    end

    it "strips RE: (uppercase)" do
      expect(described_class.normalize("RE: Hello")).to eq("Hello")
    end

    it "strips re: (lowercase)" do
      expect(described_class.normalize("re: Hello")).to eq("Hello")
    end

    it "strips Fwd:" do
      expect(described_class.normalize("Fwd: Hello")).to eq("Hello")
    end

    it "strips FWD:" do
      expect(described_class.normalize("FWD: Hello")).to eq("Hello")
    end

    it "strips Fw:" do
      expect(described_class.normalize("Fw: Hello")).to eq("Hello")
    end

    it "strips FW:" do
      expect(described_class.normalize("FW: Hello")).to eq("Hello")
    end

    # ---- Stacked prefixes (the main bug) ----

    it "strips Re: Fwd: Re:" do
      expect(described_class.normalize("Re: Fwd: Re: Meeting")).to eq("Meeting")
    end

    it "strips deeply nested prefixes" do
      expect(described_class.normalize("Re: Re: Re: Re: Re: Topic")).to eq("Topic")
    end

    it "strips mixed Re/Fwd chain" do
      expect(described_class.normalize("Fwd: Re: Fwd: Re: Hello")).to eq("Hello")
    end

    # ---- Numbered prefixes: Re[2]: Fw[5]: ----

    it "strips Re[2]:" do
      expect(described_class.normalize("Re[2]: Hello")).to eq("Hello")
    end

    it "strips Fw[3]:" do
      expect(described_class.normalize("Fw[3]: Hello")).to eq("Hello")
    end

    it "strips mixed numbered and unnumbered" do
      expect(described_class.normalize("Re: Re[4]: Fwd[2]: Budget")).to eq("Budget")
    end

    # ---- Scandinavian: Sv: (Swedish/Norwegian/Danish) ----

    it "strips Sv:" do
      expect(described_class.normalize("Sv: Möte imorgon")).to eq("Möte imorgon")
    end

    it "strips SV:" do
      expect(described_class.normalize("SV: Möte imorgon")).to eq("Möte imorgon")
    end

    it "strips Sv: Sv: (stacked)" do
      expect(described_class.normalize("Sv: Sv: Rapport")).to eq("Rapport")
    end

    # ---- German: Aw: / Wg: ----

    it "strips Aw:" do
      expect(described_class.normalize("Aw: Besprechung")).to eq("Besprechung")
    end

    it "strips AW:" do
      expect(described_class.normalize("AW: Besprechung")).to eq("Besprechung")
    end

    it "strips Wg:" do
      expect(described_class.normalize("Wg: Besprechung")).to eq("Besprechung")
    end

    it "strips AW: WG: (German reply to forward)" do
      expect(described_class.normalize("AW: WG: Rechnung")).to eq("Rechnung")
    end

    # ---- French: Rép: / Tr: ----

    it "strips Rép:" do
      expect(described_class.normalize("Rép: Réunion")).to eq("Réunion")
    end

    it "strips Tr:" do
      expect(described_class.normalize("Tr: Document")).to eq("Document")
    end

    it "strips Tr: Rép: (French forward + reply)" do
      expect(described_class.normalize("Tr: Rép: Projet")).to eq("Projet")
    end

    # ---- Finnish: Vs: ----

    it "strips Vs:" do
      expect(described_class.normalize("Vs: Kokous")).to eq("Kokous")
    end

    it "strips VS:" do
      expect(described_class.normalize("VS: Kokous")).to eq("Kokous")
    end

    # ---- Italian: Ref: / Rif: ----

    it "strips Ref:" do
      expect(described_class.normalize("Ref: Riunione")).to eq("Riunione")
    end

    it "strips Rif:" do
      expect(described_class.normalize("Rif: Riunione")).to eq("Riunione")
    end

    # ---- Turkish: Ynt: ----

    it "strips Ynt:" do
      expect(described_class.normalize("Ynt: Toplantı")).to eq("Toplantı")
    end

    it "strips YNT:" do
      expect(described_class.normalize("YNT: Toplantı")).to eq("Toplantı")
    end

    # ---- Polish: Odp: ----

    it "strips Odp:" do
      expect(described_class.normalize("Odp: Spotkanie")).to eq("Spotkanie")
    end

    it "strips ODP:" do
      expect(described_class.normalize("ODP: Spotkanie")).to eq("Spotkanie")
    end

    # ---- Welsh: Atb: ----

    it "strips Atb:" do
      expect(described_class.normalize("Atb: Cyfarfod")).to eq("Cyfarfod")
    end

    # ---- Portuguese: Enc: / Res: ----

    it "strips Enc:" do
      expect(described_class.normalize("Enc: Relatório")).to eq("Relatório")
    end

    it "strips Res:" do
      expect(described_class.normalize("Res: Relatório")).to eq("Relatório")
    end

    it "strips Res: Enc: (Portuguese reply to forward)" do
      expect(described_class.normalize("Res: Enc: Contrato")).to eq("Contrato")
    end

    # ---- Dutch: Antw: / Doorst: ----

    it "strips Antw:" do
      expect(described_class.normalize("Antw: Vergadering")).to eq("Vergadering")
    end

    it "strips Doorst:" do
      expect(described_class.normalize("Doorst: Vergadering")).to eq("Vergadering")
    end

    # ---- Hungarian: Vá: ----

    it "strips Vá:" do
      expect(described_class.normalize("Vá: Megbeszélés")).to eq("Megbeszélés")
    end

    it "strips Va:" do
      expect(described_class.normalize("Va: Megbeszélés")).to eq("Megbeszélés")
    end

    # ---- Icelandic: Fs: / Vb: ----

    it "strips Fs:" do
      expect(described_class.normalize("Fs: Fundur")).to eq("Fundur")
    end

    it "strips Vb:" do
      expect(described_class.normalize("Vb: Fundur")).to eq("Fundur")
    end

    # ---- Norwegian Bokmål: Rv: ----

    it "strips Rv:" do
      expect(described_class.normalize("Rv: Rapport")).to eq("Rapport")
    end

    # ---- Czech/Slovak: Pd: ----

    it "strips Pd:" do
      expect(described_class.normalize("Pd: Schůzka")).to eq("Schůzka")
    end

    # ---- Afrikaans: Beantw: ----

    it "strips Beantw:" do
      expect(described_class.normalize("Beantw: Vergadering")).to eq("Vergadering")
    end

    # ---- Scandinavian full word: Svar: ----

    it "strips Svar:" do
      expect(described_class.normalize("Svar: Rapport")).to eq("Rapport")
    end

    # ---- Chinese Simplified: 回复: / 转发: ----

    it "strips 回复:" do
      expect(described_class.normalize("回复: 会议安排")).to eq("会议安排")
    end

    it "strips 转发:" do
      expect(described_class.normalize("转发: 会议安排")).to eq("会议安排")
    end

    it "strips 回复: 转发: (stacked)" do
      expect(described_class.normalize("回复: 转发: 合同")).to eq("合同")
    end

    # ---- Chinese Traditional: 回覆: / 轉寄: ----

    it "strips 回覆:" do
      expect(described_class.normalize("回覆: 會議")).to eq("會議")
    end

    it "strips 轉寄:" do
      expect(described_class.normalize("轉寄: 會議")).to eq("會議")
    end

    # ---- Korean: 답장: / 전달: ----

    it "strips 답장:" do
      expect(described_class.normalize("답장: 회의")).to eq("회의")
    end

    it "strips 전달:" do
      expect(described_class.normalize("전달: 회의")).to eq("회의")
    end

    # ---- Japanese: 返信: / 転送: ----

    it "strips 返信:" do
      expect(described_class.normalize("返信: 会議")).to eq("会議")
    end

    it "strips 転送:" do
      expect(described_class.normalize("転送: 会議")).to eq("会議")
    end

    # ---- Hebrew: השב: / הועבר: ----

    it "strips השב:" do
      expect(described_class.normalize("השב: פגישה")).to eq("פגישה")
    end

    it "strips הועבר:" do
      expect(described_class.normalize("הועבר: פגישה")).to eq("פגישה")
    end

    # ---- Arabic: رد: / إعادة توجيه: ----

    it "strips رد:" do
      expect(described_class.normalize("رد: اجتماع")).to eq("اجتماع")
    end

    it "strips إعادة توجيه:" do
      expect(described_class.normalize("إعادة توجيه: اجتماع")).to eq("اجتماع")
    end

    # ---- Hindi: उत्तर: / अग्रेषित: ----

    it "strips उत्तर:" do
      expect(described_class.normalize("उत्तर: बैठक")).to eq("बैठक")
    end

    it "strips अग्रेषित:" do
      expect(described_class.normalize("अग्रेषित: बैठक")).to eq("बैठक")
    end

    # ---- Greek: ΑΠ: / ΠΡΘ: ----

    it "strips ΑΠ:" do
      expect(described_class.normalize("ΑΠ: Συνάντηση")).to eq("Συνάντηση")
    end

    it "strips ΠΡΘ:" do
      expect(described_class.normalize("ΠΡΘ: Συνάντηση")).to eq("Συνάντηση")
    end

    # ---- Russian: ОТВ: / ПЕР: ----

    it "strips ОТВ:" do
      expect(described_class.normalize("ОТВ: Встреча")).to eq("Встреча")
    end

    it "strips ПЕР:" do
      expect(described_class.normalize("ПЕР: Встреча")).to eq("Встреча")
    end

    # ---- Bulgarian: НА: ----

    it "strips НА:" do
      expect(described_class.normalize("НА: Среща")).to eq("Среща")
    end

    # ---- Cross-language stacked prefixes ----

    it "strips Re: followed by Sv:" do
      expect(described_class.normalize("Re: Sv: Project update")).to eq("Project update")
    end

    it "strips AW: followed by Re: followed by Fwd:" do
      expect(described_class.normalize("AW: Re: Fwd: Rechnung #1234")).to eq("Rechnung #1234")
    end

    it "strips 回复: followed by Re:" do
      expect(described_class.normalize("回复: Re: 项目更新")).to eq("项目更新")
    end

    it "strips Odp: Fwd: Sv:" do
      expect(described_class.normalize("Odp: Fwd: Sv: Harmonogram")).to eq("Harmonogram")
    end

    it "strips Ynt: Re[3]: Fwd:" do
      expect(described_class.normalize("Ynt: Re[3]: Fwd: Toplantı notu")).to eq("Toplantı notu")
    end

    # ---- Mailing list tags ----

    it "strips [listname]" do
      expect(described_class.normalize("[dev] Build broken")).to eq("Build broken")
    end

    it "strips [PATCH] tag" do
      expect(described_class.normalize("[PATCH] Fix memory leak")).to eq("Fix memory leak")
    end

    it "strips [PATCH v2 3/5] tag" do
      expect(described_class.normalize("[PATCH v2 3/5] Fix memory leak")).to eq("Fix memory leak")
    end

    it "strips nested list tags" do
      expect(described_class.normalize("[linux-kernel] [PATCH] Fix bug")).to eq("Fix bug")
    end

    it "strips list tag combined with Re:" do
      expect(described_class.normalize("Re: [dev] Build broken")).to eq("Build broken")
    end

    it "strips [tag] Re: [tag] mixed" do
      expect(described_class.normalize("[rails] Re: [core] API changes")).to eq("API changes")
    end

    it "does not strip tags longer than 40 chars" do
      long_tag = "[#{"a" * 41}]"
      expect(described_class.normalize("#{long_tag} Subject")).to eq("#{long_tag} Subject")
    end

    # ---- Whitespace handling ----

    it "strips leading whitespace" do
      expect(described_class.normalize("   Re: Hello")).to eq("Hello")
    end

    it "strips trailing whitespace" do
      expect(described_class.normalize("Re: Hello   ")).to eq("Hello")
    end

    it "handles extra whitespace around prefix" do
      expect(described_class.normalize("  Re:   Hello  ")).to eq("Hello")
    end

    it "collapses multiple internal spaces" do
      expect(described_class.normalize("Re:  Hello    World")).to eq("Hello World")
    end

    it "handles tabs and newlines" do
      expect(described_class.normalize("Re:\t Hello\nWorld")).to eq("Hello World")
    end

    # ---- Edge cases ----

    it "returns empty string when subject is only prefixes" do
      expect(described_class.normalize("Re: Fwd:")).to eq("")
    end

    it "returns empty string when subject is only list tags" do
      expect(described_class.normalize("[dev]")).to eq("")
    end

    it "returns empty string when subject is Re: [tag]" do
      expect(described_class.normalize("Re: [dev]")).to eq("")
    end

    it "preserves subject that looks like a prefix but isn't" do
      expect(described_class.normalize("Retirement planning")).to eq("Retirement planning")
    end

    it "preserves 'Res' without colon" do
      expect(described_class.normalize("Resolution discussion")).to eq("Resolution discussion")
    end

    it "handles colon in subject body" do
      expect(described_class.normalize("Re: Meeting: 3pm")).to eq("Meeting: 3pm")
    end

    it "handles subject with only special characters" do
      expect(described_class.normalize("Re: !!!")).to eq("!!!")
    end

    it "handles very long subject" do
      long = "Re: " + "a" * 1000
      expect(described_class.normalize(long)).to eq("a" * 1000)
    end

    it "handles emoji in subject" do
      expect(described_class.normalize("Re: 🎉 Launch party")).to eq("🎉 Launch party")
    end

    it "does not strip partial prefix matches mid-subject" do
      expect(described_class.normalize("We need to review the report")).to eq("We need to review the report")
    end

    it "is idempotent" do
      subject = "Re: Fwd: [dev] Meeting"
      normalized = described_class.normalize(subject)
      expect(described_class.normalize(normalized)).to eq(normalized)
    end
  end
end
