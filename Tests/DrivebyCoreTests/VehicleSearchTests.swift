import XCTest
@testable import DrivebyCore

final class VehicleSearchTests: XCTestCase {
    let makes = ["Acura", "Alfa Romeo", "Chevrolet", "Honda", "Land Rover", "Mercedes-Benz", "Mini", "Toyota", "Volkswagen"]
    let years = ["2026", "2025", "2019", "2018"]

    func testParseYearMakeModel() {
        let p = VehicleSearch.parse("2019 honda civic", years: years, makes: makes)
        XCTAssertEqual(p, .init(year: "2019", make: "Honda", rest: ["civic"]))
    }

    func testParseMultiWordMakesAndNicknames() {
        XCTAssertEqual(VehicleSearch.parse("mercedes benz c300", years: years, makes: makes).make, "Mercedes-Benz")
        XCTAssertEqual(VehicleSearch.parse("mercedes c300", years: years, makes: makes).rest, ["c300"])
        XCTAssertEqual(VehicleSearch.parse("Land Rover Defender", years: years, makes: makes).make, "Land Rover")
        XCTAssertEqual(VehicleSearch.parse("chevy malibu", years: years, makes: makes).make, "Chevrolet")
        XCTAssertEqual(VehicleSearch.parse("vw jetta 2018", years: years, makes: makes), .init(year: "2018", make: "Volkswagen", rest: ["jetta"]))
    }

    func testPartialQueryMatchesMakes() {
        let p = VehicleSearch.parse("hon", years: years, makes: makes)
        XCTAssertNil(p.make)
        XCTAssertEqual(VehicleSearch.matchMakes("hon", makes: makes), ["Honda"])
        XCTAssertEqual(VehicleSearch.matchMakes("m", makes: makes), ["Mercedes-Benz", "Mini", "Alfa Romeo"])  // prefix first, then substring
        XCTAssertEqual(VehicleSearch.matchMakes("chev", makes: makes).first, "Chevrolet")
        XCTAssertEqual(VehicleSearch.matchMakes("", makes: makes).count, makes.count)
    }

    func testModelFilterIgnoresDashesAndCase() {
        let models = ["Accord", "Civic 2Dr", "Civic 4Dr", "Civic HB", "CR-V AWD", "CR-V FWD", "Pilot AWD"]
        XCTAssertEqual(VehicleSearch.matchModels(["civic"], models: models), ["Civic 2Dr", "Civic 4Dr", "Civic HB"])
        XCTAssertEqual(VehicleSearch.matchModels(["crv", "awd"], models: models), ["CR-V AWD"])
        XCTAssertEqual(VehicleSearch.matchModels(["awd"], models: models), ["CR-V AWD", "Pilot AWD"])
        XCTAssertEqual(VehicleSearch.matchModels([], models: models).count, models.count)
    }
}
