import Foundation
import Testing
@testable import SkyKit

@Suite struct SatelliteInfoTests {
    let celesTrak = """
    OBJECT_NAME,OBJECT_ID,NORAD_CAT_ID,OBJECT_TYPE,OPS_STATUS_CODE,OWNER,LAUNCH_DATE,LAUNCH_SITE,DECAY_DATE,PERIOD,INCLINATION,APOGEE,PERIGEE,RCS,DATA_STATUS_CODE,ORBIT_CENTER,ORBIT_TYPE
    SL-1 R/B,1957-001A,1,R/B,D,CIS,1957-10-04,TYMSC,1957-12-01,96.19,65.10,938,214,20.4200,,EA,IMP
    VANGUARD 1,1958-002B,5,PAY,-,US,1958-03-17,AFETR,,132.65,34.25,3829,650,0.1220,,EA,ORB
    HST,1990-037B,20580,PAY,+,US,1990-04-24,AFETR,,93.99,28.47,471,468,28.0799,,EA,ORB
    "ISS (ZARYA), TEST",1998-067A,25544,PAY,+,ISS,1998-11-20,TYMSC,,92.96,51.63,424,415,399.0524,,EA,ORB
    CSS (TIANHE),2021-035A,48274,PAY,+,PRC,2021-04-29,WSC,,92.24,41.47,386,383,,,EA,ORB
    """

    let gcat = "#JCAT\tSatcat\tName\tLength\tLFlag\tDiameter\tDFlag\tSpan\tSpanFlag\tShape\n"
        + "# Updated 2026 Oct 24\n"
        + "S00005    \t00005\tVanguard I\t  0.1 \t \t  0.1 \t \t  0.1 \t \tSphere\n"
        + "S48274    \t48274\tTianhe\t 16.6 \t \t  4.2 \t \t 30.0 \t \tStep Cyl + 2 Pan\n"
        + "S99999    \t99999\tNot in orbit\t  1.0 \t \t  -  \t \t  - \t \tBox\n"

    var info: [String: SatelliteInfo] {
        var info = SatelliteCatalogInfo.parseCelesTrak(celesTrak)
        SatelliteCatalogInfo.addGCAT(gcat, to: &info)
        return info
    }

    @Test func parsesSatcatAndSkipsDecayed() {
        let info = info
        #expect(info["1"] == nil)
        #expect(info.count == 4)
        let iss = info["25544"]!
        #expect(iss.cosparID == "1998-067A")
        #expect(iss.owner == "ISS")  // a quoted name with a comma doesn't shift the columns
        #expect(iss.radarCrossSection == 399.0524)
        #expect(iss.period == 92.96 && iss.perigee == 415 && iss.apogee == 424)
        #expect(info["48274"]?.radarCrossSection == nil)
    }

    @Test func addsDimensionsFromGCAT() {
        let tianhe = info["48274"]!
        #expect(tianhe.length == 16.6 && tianhe.diameter == 4.2 && tianhe.span == 30)
        #expect(tianhe.shape == "Step Cyl + 2 Pan")
        #expect(info[SatelliteCatalogInfo.key("00005")]?.shape == "Sphere")
        #expect(info["99999"] == nil)
    }

    @Test func sizeClassPrefersRadar() {
        let info = info
        #expect(info["5"]?.sizeClass == .medium)      // RCS 0.122 m², though only 0.1 m across
        #expect(info["48274"]?.sizeClass == .large)   // no RCS: 30 m span
        var tiny = SatelliteInfo()
        tiny.length = 0.1
        #expect(tiny.sizeClass == .small)
        #expect(SatelliteInfo().sizeClass == nil)
    }

    @Test func queries() {
        let info = info
        func names(_ query: String) -> Set<String> {
            let q = SatelliteQuery(query)
            return Set(info.filter { q.matches(name: "sat \($0.key)", noradID: $0.key, info: $0.value) }.keys)
        }
        #expect(names("owner=PRC") == ["48274"])
        #expect(names("owner:us") == ["5", "20580"])
        #expect(names("launched>2000") == ["48274"])
        #expect(names("launched=1998") == ["25544"])
        #expect(names("launched<1990-05") == ["5", "20580"])
        #expect(names("period<93") == ["25544", "48274"])
        #expect(names("period=93") == ["25544"])
        #expect(names("inc>50 rcs>100") == ["25544"])
        #expect(names("span>=30") == ["48274"])
        #expect(names("size=large") == ["20580", "25544", "48274"])
        #expect(names("type=payload") == ["5", "20580", "25544", "48274"])
        #expect(names("sphere") == ["5"])
        #expect(names("00005") == ["5"])
        #expect(names("1998-067") == ["25544"])
    }

    @Test func plainWordsAreNotAttributes() {
        #expect(!SatelliteQuery("ISS").comparesAttributes)
        #expect(SatelliteQuery("ISS period<100").comparesAttributes)
        #expect(!SatelliteQuery("NOAA-19").comparesAttributes)
    }
}
